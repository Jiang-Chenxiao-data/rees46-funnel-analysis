#!/usr/bin/env python
"""Recompute archived REES46 funnel aggregates from the fixed clean Parquet.

Independent method: sort events, scan each user-product history with a state
machine, then deduplicate users. No MySQL tables or archived SQL are executed.
Only aggregate results are exported. Input events are never changed.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import platform
import time
from datetime import datetime, timezone
from pathlib import Path

import numba
import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "data/analysis_output/funnel_20260922"
START = 1569888000  # 2019-10-01 00:00:00 UTC
END = 1583020799  # 2020-02-29 23:59:59 UTC
WINDOW = 7 * 86400
CUTOFF = END - WINDOW
EVENTS = ["view", "cart", "remove_from_cart", "purchase"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@numba.njit
def scan_sorted(users, products, times, codes, group_count):
    """One row [user, product, first view, first cart, view buy, strict buy]."""
    output = np.empty((group_count, 6), dtype=np.int64)
    count = 0
    user = product = view = cart = view_buy = strict_buy = -1
    for i in range(len(users)):
        if i == 0 or users[i] != user or products[i] != product:
            if view >= 0:
                output[count] = user, product, view, cart, view_buy, strict_buy
                count += 1
            user, product = users[i], products[i]
            view = cart = view_buy = strict_buy = -1
        t, code = times[i], codes[i]
        if code == 1 and view < 0:
            view = t
        elif code == 2 and view >= 0 and t > view and cart < 0:
            cart = t
        elif code == 4:
            if view >= 0 and t > view and view_buy < 0:
                view_buy = t
            if cart >= 0 and t > cart and strict_buy < 0:
                strict_buy = t
    if view >= 0:
        output[count] = user, product, view, cart, view_buy, strict_buy
        count += 1
    return output[:count].copy()


def build_paths(users, products, times, codes):
    # Event code is not a tie-breaker. Strict > rules make same-second order irrelevant.
    order = np.lexsort((times, products, users))
    users, products = users[order], products[order]
    times, codes = times[order], codes[order]
    groups = 1 + int(np.count_nonzero(
        (users[1:] != users[:-1]) | (products[1:] != products[:-1])
    )) if len(users) else 0
    return scan_sorted(users, products, times, codes, groups)


def user_counts(paths, window=None):
    users = paths[:, 0]
    flags = [np.ones(len(paths), dtype=bool)]
    for col in (3, 4, 5):
        valid = paths[:, col] >= 0
        if window is not None:
            valid &= paths[:, col] <= paths[:, 2] + window
        flags.append(valid)
    names = ("view_users", "cart_users", "view_purchase_users", "strict_purchase_users")
    return {name: int(np.unique(users[flag]).size) for name, flag in zip(names, flags)}


def first_strict_paths(paths):
    strict = paths[paths[:, 5] >= 0]
    # First completed purchase, not the fastest duration. Product ID only resolves
    # remaining exact time ties and cannot change the selected duration.
    order = np.lexsort((strict[:, 1], strict[:, 3], strict[:, 2], strict[:, 5], strict[:, 0]))
    strict = strict[order]
    keep = np.r_[True, strict[1:, 0] != strict[:-1, 0]] if len(strict) else np.array([], dtype=bool)
    return strict[keep]


def self_test():
    # Synthetic controls are deliberately separate from real-data results.
    rows = [
        (1, 10, 100, 1), (1, 10, 100, 2), (1, 10, 101, 2),
        (1, 10, 101, 4), (1, 10, 102, 4),  # same-second steps rejected
        (2, 10, CUTOFF, 1), (2, 10, CUTOFF+1, 2), (2, 10, END, 4),
        (3, 10, CUTOFF+1, 1), (3, 10, CUTOFF+2, 2), (3, 10, END, 4),
        (4, 10, 100, 1), (4, 10, 100+WINDOW, 2), (4, 10, 101+WINDOW, 4),
        (5, 10, 50, 2), (5, 10, 60, 4), (5, 10, 100, 1),
        (5, 10, 101, 4), (5, 10, 102, 2), (5, 10, 103, 4),
        (6, 10, 100, 1), (6, 10, 100+WINDOW, 1),
        (6, 10, 101+WINDOW, 2), (6, 10, 102+WINDOW, 4),  # no restart
        (7, 10, 100, 1), (7, 10, 101, 2), (7, 10, 102, 4),
        (7, 20, 100, 1), (7, 20, 101, 2), (7, 20, 102, 4),
        (8, 10, 100, 2), (8, 10, 101, 4),  # no view -> excluded
        (9, 10, 100, 1), (9, 10, 101, 2), (9, 10, 200, 4),
        (9, 20, 198, 1), (9, 20, 199, 2), (9, 20, 201, 4),
    ]
    raw = np.array(rows, dtype=np.int64)
    paths = build_paths(raw[:, 0], raw[:, 1], raw[:, 2], raw[:, 3])
    p = {(int(r[0]), int(r[1])): r for r in paths}
    assert tuple(p[1, 10][2:]) == (100, 101, 101, 102)
    assert user_counts(paths[paths[:, 0] == 2], WINDOW)["strict_purchase_users"] == 1
    assert not np.any(paths[(paths[:, 2] <= CUTOFF), 0] == 3)
    assert user_counts(paths[paths[:, 0] == 4], WINDOW)["cart_users"] == 1
    assert user_counts(paths[paths[:, 0] == 4], WINDOW)["strict_purchase_users"] == 0
    assert tuple(p[5, 10][2:]) == (100, 102, 101, 103)
    assert user_counts(paths[paths[:, 0] == 6], WINDOW)["cart_users"] == 0
    assert user_counts(paths[paths[:, 0] == 7])["strict_purchase_users"] == 1
    assert (8, 10) not in p
    first = first_strict_paths(paths[paths[:, 0] == 9])
    assert int(first[0, 5] - first[0, 2]) == 100
    # Reverse all input rows: tied timestamps must produce identical paths.
    reversed_paths = build_paths(raw[::-1, 0], raw[::-1, 1], raw[::-1, 2], raw[::-1, 3])
    assert np.array_equal(paths, reversed_paths)
    return 11


def write_csv(path, rows):
    if not rows:
        raise ValueError(f"No output rows for {path}")
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def utc_text(seconds):
    return datetime.fromtimestamp(int(seconds), timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def run(input_path, output_dir):
    started = datetime.now(timezone.utc).isoformat()
    start_clock = time.perf_counter()
    controls = self_test()
    reported = json.loads((ARCHIVE / "reported_results.json").read_text(encoding="utf-8"))
    audit_path = ROOT / "data/processed/clean_data/cleaning_audit.json"
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    source_hash = sha256(input_path)
    if source_hash != audit["output_sha256"]:
        raise ValueError("Parquet SHA-256 differs from the fixed cleaning audit; stop.")
    print("Source fingerprint verified; reading full clean data.", flush=True)
    table = pq.read_table(input_path)
    checks = []

    def check(name, actual, expected, category="full_data"):
        checks.append({"check": name, "actual": actual, "expected": expected,
                       "passed": actual == expected, "category": category})

    check("clean_row_count", table.num_rows, audit["clean_rows"])
    check("column_names", "|".join(table.column_names), "|".join(audit["output_columns"]))
    for name in ("event_time", "event_type", "user_id", "product_id"):
        check(f"null_{name}", table[name].null_count, 0)
    check("event_time_timezone", table.schema.field("event_time").type.tz, "UTC")
    times_ns = pc.cast(table["event_time"], pa.int64()).to_numpy()
    check("subsecond_timestamps", int(np.count_nonzero(times_ns % 1_000_000_000)), 0)
    times = times_ns // 1_000_000_000
    del times_ns
    check("observation_start_utc", utc_text(times.min()), reported["observation_start_utc"])
    check("observation_end_utc", utc_text(times.max()), reported["observation_end_utc"])
    users = table["user_id"].to_numpy().copy()
    products = table["product_id"].to_numpy().copy()
    check("all_event_distinct_users", int(np.unique(users).size), 1639358)
    import_values = {
        "row_count": table.num_rows,
        "view_rows": int(pc.sum(pc.equal(table["event_type"], "view")).as_py()),
        "cart_rows": int(pc.sum(pc.equal(table["event_type"], "cart")).as_py()),
        "remove_from_cart_rows": int(pc.sum(pc.equal(table["event_type"], "remove_from_cart")).as_py()),
        "purchase_rows": int(pc.sum(pc.equal(table["event_type"], "purchase")).as_py()),
        "null_session_rows": table["user_session"].null_count,
        "zero_price_rows": int(pc.sum(pc.equal(table["price"], 0)).as_py()),
        "negative_price_rows": int(pc.sum(pc.less(table["price"], 0)).as_py()),
        "min_price": float(pc.min(table["price"]).as_py()),
        "max_price": float(pc.max(table["price"]).as_py()),
        "min_event_time_utc": utc_text(times.min()),
        "max_event_time_utc": utc_text(times.max()),
    }
    import_expected = [19583742, 9656790, 5652991, 2987859, 1286102, 4085,
                       86326, 124, -79.37, 327.78,
                       "2019-10-01 00:00:00", "2020-02-29 23:59:59"]
    for (name, value), expected in zip(import_values.items(), import_expected):
        check("import_" + name, value, expected)
    lookup = pc.index_in(table["event_type"], value_set=pa.array(EVENTS))
    check("unknown_event_rows", lookup.null_count, 0)
    if any(not c["passed"] for c in checks):
        raise ValueError("Source version/schema checks failed: " +
                         repr([c for c in checks if not c["passed"]]))
    codes = lookup.to_numpy().astype(np.int8) + 1
    del table, lookup
    keep = codes != 3
    users, products, times, codes = users[keep], products[keep], times[keep], codes[keep]
    del keep
    print(f"Scanning {len(users):,} view/cart/purchase events in user-product time order.", flush=True)
    paths = build_paths(users, products, times, codes)
    del users, products, times, codes
    print(f"Rebuilt {len(paths):,} first-view paths; aggregating and reconciling.", flush=True)

    no_window = user_counts(paths)
    eligible = paths[paths[:, 2] <= CUTOFF]
    seven_day = user_counts(eligible, WINDOW)
    for scope, result in (("no_window", no_window), ("seven_day", seven_day)):
        for name, value in result.items():
            check(scope + "." + name, value, reported[scope][name], "handoff_reconciliation")

    first = first_strict_paths(paths)
    durations = np.sort(first[:, 5] - first[:, 2])
    duration_results = {"users": len(durations), "min": int(durations.min()),
                        "max": int(durations.max())}
    for name, probability in (("p50", .50), ("p75", .75), ("p90", .90), ("p95", .95)):
        duration_results[name] = int(durations[math.ceil(probability * len(durations)) - 1])
    for name, value in duration_results.items():
        check("duration." + name, value, reported["first_strict_duration_seconds"][name],
              "handoff_reconciliation")
    coverage = {}
    for days in (1, 7, 14, 30):
        coverage[str(days)] = int(np.count_nonzero(durations <= days * 86400))
        check(f"coverage.{days}d", coverage[str(days)],
              reported["first_strict_coverage_users"][str(days)], "handoff_reconciliation")

    check("invalid_cart_order", int(np.count_nonzero((paths[:, 3] >= 0) & (paths[:, 3] <= paths[:, 2]))), 0)
    check("invalid_view_purchase_order", int(np.count_nonzero((paths[:, 4] >= 0) & (paths[:, 4] <= paths[:, 2]))), 0)
    check("invalid_strict_order", int(np.count_nonzero(
        (paths[:, 5] >= 0) & ((paths[:, 3] < 0) | (paths[:, 5] <= paths[:, 3])))), 0)
    check("invalid_purchase_branch_relation", int(np.count_nonzero(
        (paths[:, 5] >= 0) & ((paths[:, 4] < 0) | (paths[:, 4] > paths[:, 5])))), 0)
    check("invalid_first_strict_duration", int(np.count_nonzero(durations <= 0)), 0)
    strict7 = (eligible[:, 5] >= 0) & (eligible[:, 5] <= eligible[:, 2] + WINDOW)
    cart7 = (eligible[:, 3] >= 0) & (eligible[:, 3] <= eligible[:, 2] + WINDOW)
    check("seven_day_strict_without_cart_paths", int(np.count_nonzero(strict7 & ~cart7)), 0)
    check("seven_day_user_monotonicity",
          seven_day["view_users"] >= seven_day["cart_users"] >= seven_day["strict_purchase_users"], True)
    check("no_window_user_monotonicity",
          no_window["view_users"] >= no_window["cart_users"] >= no_window["strict_purchase_users"], True)

    boundary = {
        "all_first_view_paths": len(paths),
        "eligible_7d_paths": len(eligible),
        "excluded_right_truncated_paths": len(paths) - len(eligible),
        "paths_starting_exactly_at_cutoff": int(np.count_nonzero(paths[:, 2] == CUTOFF)),
        "paths_starting_after_cutoff": int(np.count_nonzero(paths[:, 2] > CUTOFF)),
        "users_with_no_eligible_7d_path": no_window["view_users"] - seven_day["view_users"],
        "cart_paths_exactly_at_7d": int(np.count_nonzero(eligible[:, 3] == eligible[:, 2] + WINDOW)),
        "strict_purchase_paths_exactly_at_7d": int(np.count_nonzero(eligible[:, 5] == eligible[:, 2] + WINDOW)),
    }
    check("right_truncation_partition",
          boundary["eligible_7d_paths"] + boundary["excluded_right_truncated_paths"], len(paths))
    check("first_strict_user_count_equals_no_window_strict", len(first), no_window["strict_purchase_users"])
    check("synthetic_boundary_controls_passed", controls, 11, "synthetic")

    output_dir.mkdir(parents=True, exist_ok=True)
    count_rows, rate_rows = [], []
    for scope, result in (("no_window", no_window), ("seven_day", seven_day)):
        for metric, value in result.items():
            count_rows.append({"scope": scope, "metric": metric, "users": value,
                               "evidence": "full_clean_parquet_python_recomputation"})
        for name, numerator, denominator in (
            ("view_to_cart", "cart_users", "view_users"),
            ("cart_to_strict_purchase", "strict_purchase_users", "cart_users"),
            ("view_to_strict_purchase", "strict_purchase_users", "view_users"),
            ("view_to_purchase_branch", "view_purchase_users", "view_users"),
        ):
            n, d = result[numerator], result[denominator]
            rate_rows.append({"scope": scope, "metric": name, "numerator_users": n,
                              "denominator_users": d, "rate": n / d if d else None,
                              "rate_percent": round(n / d * 100, 2) if d else None})
    write_csv(output_dir / "funnel_counts.csv", count_rows)
    write_csv(output_dir / "funnel_rates.csv", rate_rows)
    write_csv(output_dir / "first_strict_duration.csv", [
        {"metric": name, "value": value, "unit": "users" if name == "users" else "seconds"}
        for name, value in duration_results.items()])
    write_csv(output_dir / "first_strict_coverage.csv", [
        {"window_days": int(days), "covered_users": users, "converted_user_denominator": len(first),
         "coverage_rate": users / len(first), "coverage_percent": round(users / len(first) * 100, 2)}
        for days, users in coverage.items()])
    write_csv(output_dir / "right_truncation_checks.csv", [
        {"metric": name, "value": value} for name, value in boundary.items()])
    write_csv(output_dir / "import_baseline.csv", [
        {"metric": name, "value": value} for name, value in import_values.items()])
    write_csv(output_dir / "validation_checks.csv", checks)
    passed = all(c["passed"] for c in checks)
    manifest = {
        "status": "passed" if passed else "failed",
        "scope": "full clean Parquet aggregate recomputation; not a MySQL execution",
        "started_at_utc": started,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.perf_counter() - start_clock, 3),
        "source": {"path": str(input_path.relative_to(ROOT)) if input_path.is_relative_to(ROOT) else str(input_path),
                   "sha256": source_hash, "rows": audit["clean_rows"]},
        "observation_start_utc": utc_text(START), "observation_end_utc": utc_text(END),
        "eligible_view_cutoff_utc": utc_text(CUTOFF), "window_seconds": WINDOW,
        "method": "NumPy chronological sorting + Numba state-machine scan; NumPy user deduplication and nearest-rank quantiles",
        "environment": {"python": platform.python_version(), "numpy": np.__version__,
                        "numba": numba.__version__, "pyarrow": pa.__version__, "pandas": pd.__version__},
        "check_count": len(checks), "failed_checks": [c for c in checks if not c["passed"]],
        "mysql_queries_executed": False,
        "script_sha256": sha256(Path(__file__)),
        "reported_results_sha256": sha256(ARCHIVE / "reported_results.json"),
        "output_sha256": {p.name: sha256(p) for p in sorted(output_dir.glob("*.csv"))},
    }
    (output_dir / "run_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": manifest["status"], "checks": len(checks),
                      "no_window": no_window, "seven_day": seven_day,
                      "duration": duration_results, "coverage": coverage,
                      "boundary": boundary, "elapsed_seconds": manifest["elapsed_seconds"]},
                     ensure_ascii=False), flush=True)
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=ROOT / "data/processed/clean_data/clean_data.parquet")
    parser.add_argument("--output", type=Path, default=ARCHIVE / "verification")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        print(f"{self_test()} synthetic boundary controls passed.")
    else:
        run(args.input.resolve(), args.output.resolve())

