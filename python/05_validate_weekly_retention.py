"""全量独立核对真实周留存；不连接或修改 MySQL。

使用清洗后的 Parquet，仅重算 UTC 自然周、用户周、首次观察批次和留存人数。
可选择读取 Navicat 只读 SQL 导出的“周留存核对结果.csv”，完成实际表对照。
"""
from pathlib import Path
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import csv
import gc
import hashlib
import json
import time

import numpy as np
import pandas as pd
import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "data/processed/clean_data/clean_data.parquet"
MATRIX = ROOT / "sql/周cohort留存矩阵.csv"
MYSQL_EXPORT = ROOT / "sql/周留存核对结果.csv"
OUT = ROOT / "data/analysis_output/weekly_retention_validation_20261020"
DAY_NS = 86_400_000_000_000
BASE_DAY = int(np.datetime64("2019-09-30", "D").astype(int))
END_DAY = int(np.datetime64("2020-02-29", "D").astype(int))
STRIDE = 32


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for part in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()


def rate(n, d):
    return float((Decimal(int(n)) * Decimal(100) / Decimal(int(d))).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP))


def iso(week):
    return str(np.datetime64(BASE_DAY + 7 * int(week), "D"))


def main():
    started = datetime.now(timezone.utc).isoformat()
    timer = time.perf_counter()
    OUT.mkdir(parents=True, exist_ok=True)
    checks = []
    def check(name, actual, expected, scope):
        equal = bool(actual == expected)
        checks.append(dict(check=name, status="PASS" if equal else "FAIL",
                           actual=str(actual), expected=str(expected), scope=scope))

    print("Reading all cleaned events...", flush=True)
    table = pq.read_table(SOURCE, columns=["user_id", "event_time"])
    ids = table["user_id"].combine_chunks().to_numpy()
    times = table["event_time"].combine_chunks().cast("int64").to_numpy()
    rows = len(ids)
    check("source_rows_match_archived_baseline", rows, 19_583_742, "source")
    day = times // DAY_NS
    monday = day - (day + 3) % 7
    week = (monday - BASE_DAY) // 7
    if week.min() < 0 or week.max() >= STRIDE:
        raise ValueError("Week packing range exceeded")
    if ids.min() < 0 or ids.max() > (np.iinfo(np.int64).max - STRIDE) // STRIDE:
        raise ValueError("User ID packing range exceeded")
    observed_start = str(np.datetime64(int(times.min()), "ns"))
    observed_end = str(np.datetime64(int(times.max()), "ns"))
    packed = ids * STRIDE + week
    del table, ids, times, day, monday, week
    gc.collect()

    # 方法 A：对用户周复合键做全局去重，再按首次周和周差分组。
    unique_keys, multiplicities = np.unique(packed, return_counts=True)
    del packed
    gc.collect()
    user_week_rows = len(unique_keys)
    repeated_event_groups = int((multiplicities > 1).sum())
    extra_events_in_same_user_week = int((multiplicities - 1).sum())
    del multiplicities

    uw_users = unique_keys // STRIDE
    uw_week = unique_keys % STRIDE
    users, first_positions = np.unique(uw_users, return_index=True)
    first_week = uw_week[first_positions]
    group_lengths = np.diff(np.r_[first_positions, len(unique_keys)])
    first_by_activity = np.repeat(first_week, group_lengths)
    offsets = uw_week - first_by_activity
    check("rebuilt_user_week_keys_unique", int(np.count_nonzero(np.diff(unique_keys) == 0)), 0, "independent_rebuild")
    check("rebuilt_join_rows_preserved", len(first_by_activity), user_week_rows, "independent_rebuild")
    check("rebuilt_negative_offsets", int((offsets < 0).sum()), 0, "independent_rebuild")
    check("distinct_users_match_archived_baseline", len(users), 1_639_358, "source")

    sizes = np.bincount(first_week, minlength=STRIDE)
    grouped = np.bincount(first_by_activity * STRIDE + offsets,
                          minlength=STRIDE * STRIDE).reshape(STRIDE, STRIDE)
    check("week_zero_equals_cohort_size", bool(np.array_equal(grouped[:, 0], sizes)), True, "independent_rebuild")

    cohort_rows = [dict(first_week=iso(c), cohort_users=int(sizes[c]))
                   for c in range(STRIDE) if sizes[c]]
    pd.DataFrame(cohort_rows).to_csv(OUT / "cohort_sizes.csv", index=False, encoding="utf-8-sig")

    details = []
    lookup = {}
    max_n = (END_DAY - BASE_DAY - 6) // 7
    for c in range(STRIDE):
        if not sizes[c]:
            continue
        for n in range(1, max_n + 1):
            if BASE_DAY + 7 * (c + n) + 6 <= END_DAY:
                row = dict(first_week=iso(c), retention_week=n,
                           count_first=int(sizes[c]), retained_users=int(grouped[c, n]),
                           retention_rate=rate(grouped[c, n], sizes[c]))
                details.append(row)
                lookup[(row["first_week"], n)] = row
    detail_df = pd.DataFrame(details)
    detail_df.to_csv(OUT / "retention_detail_exact.csv", index=False, encoding="utf-8-sig")

    # 方法 B：每个用户用二进制位记录在哪些自然周出现。
    # 直接针对每名合格用户判断第 N 周是否出现，不从批次汇总表取人数。
    bitmaps = np.bitwise_or.reduceat(np.left_shift(np.uint64(1), uw_week.astype(np.uint64)),
                                     first_positions)
    totals = []
    for n in range(1, max_n + 1):
        eligible = BASE_DAY + 7 * (first_week + n) + 6 <= END_DAY
        target_week = first_week + n
        # 不合格用户可能超过位移范围，因此先筛选再移位。
        returned = ((bitmaps[eligible] >> target_week[eligible].astype(np.uint64)) & np.uint64(1))
        direct_users = int(eligible.sum())
        direct_retained = int(returned.sum())
        scoped = detail_df[detail_df.retention_week == n]
        summed_users = int(scoped.count_first.sum())
        summed_retained = int(scoped.retained_users.sum())
        check(f"week_{n:02d}_denominator_detail_vs_direct_users", summed_users, direct_users, "independent_methods")
        check(f"week_{n:02d}_numerator_detail_vs_direct_users", summed_retained, direct_retained, "independent_methods")
        totals.append(dict(retention_week=n, first_week_users=direct_users,
                           retention_users=direct_retained, retention_rate=rate(direct_retained, direct_users),
                           detail_sum_users=summed_users, detail_sum_retained=summed_retained,
                           eligible_cohorts=len(scoped)))
    overall = pd.DataFrame(totals)
    overall.to_csv(OUT / "overall_exact.csv", index=False, encoding="utf-8-sig")

    # 对照用户的全部 20 x 20 CSV 矩阵，逐格检查四舍五入结果与空白。
    matrix = pd.read_csv(MATRIX, encoding="utf-8-sig")
    matrix["first_week"] = pd.to_datetime(matrix.first_week, dayfirst=True).dt.strftime("%Y-%m-%d")
    comparisons = []
    for _, row in matrix.iterrows():
        c = row.first_week
        expected_size = next((r["cohort_users"] for r in cohort_rows if r["first_week"] == c), None)
        check(f"matrix_cohort_size_{c}", int(row.cohort_users), expected_size, "mysql_matrix_export")
        for n in range(1, max_n + 1):
            value = row[f"retention_rate_{n}"]
            expected = lookup.get((c, n))
            passed = bool(pd.isna(value)) if expected is None else bool(
                pd.notna(value) and abs(float(value) - expected["retention_rate"]) < 1e-9)
            comparisons.append(dict(first_week=c, retention_week=n,
                                    exported_rate="" if pd.isna(value) else float(value),
                                    recomputed_rate="" if expected is None else expected["retention_rate"],
                                    status="PASS" if passed else "FAIL"))
    pd.DataFrame(comparisons).to_csv(OUT / "matrix_comparison.csv", index=False, encoding="utf-8-sig")
    check("all_400_matrix_cells_agree", sum(r["status"] == "PASS" for r in comparisons), 400, "mysql_matrix_export")
    check("matrix_first_week_users_total", int(matrix.cohort_users.sum()), int(overall.iloc[0].first_week_users), "mysql_matrix_export")
    check("full_eligible_detail_cells", len(details), 210, "independent_rebuild")

    # 先前 Navicat 截图可见第 1～16 周，以下为人工转录的精确人数。
    screenshot = [
        (1,1510536,132913,8.80),(2,1440061,79939,5.55),
        (3,1367393,60629,4.43),(4,1286196,48869,3.80),
        (5,1215290,41666,3.43),(6,1137909,35836,3.15),
        (7,1058481,32314,3.05),(8,1000335,28587,2.86),
        (9,934853,25065,2.68),(10,865156,22358,2.58),
        (11,792239,19641,2.48),(12,722784,17600,2.44),
        (13,646255,16253,2.51),(14,569075,15717,2.76),
        (15,500174,14344,2.87),(16,427461,12446,2.91)]
    screenshot_rows = []
    for n, den, num, pct in screenshot:
        got = totals[n - 1]
        passed = got["first_week_users"] == den and got["retention_users"] == num and abs(got["retention_rate"] - pct) < 1e-9
        screenshot_rows.append(dict(retention_week=n, screenshot_users=den, screenshot_retained=num,
                                    screenshot_rate=pct, recomputed_users=got["first_week_users"],
                                    recomputed_retained=got["retention_users"], recomputed_rate=got["retention_rate"],
                                    status="PASS" if passed else "FAIL"))
    pd.DataFrame(screenshot_rows).to_csv(OUT / "screenshot_overall_comparison.csv", index=False, encoding="utf-8-sig")
    check("visible_screenshot_weeks_1_to_16_agree", sum(r["status"] == "PASS" for r in screenshot_rows), 16, "mysql_screenshot")

    # 若用户补充只读导出，则核对数据库物理表和精确明细。
    mysql_verified = False
    if MYSQL_EXPORT.exists():
        live = pd.read_csv(MYSQL_EXPORT, encoding="utf-8-sig")
        required = {"record_type", "check_name", "first_week", "retention_week",
                    "cohort_users", "retained_users", "retention_rate", "check_value"}
        if not required.issubset(live.columns):
            raise ValueError("MySQL 核对导出列不完整")
        check("mysql_export_record_types", sorted(live.record_type.unique().tolist()), ["check", "detail", "overall"], "mysql_readonly_export")
        check("mysql_export_total_rows", len(live), 238, "mysql_readonly_export")
        mysql_checks = live[live.record_type == "check"].set_index("check_name").check_value
        expected_checks = dict(user_week_duplicate_groups=0, user_week_duplicate_extra_rows=0,
                               diff_duplicate_groups=0, detail_duplicate_groups=0,
                               user_week_rows=user_week_rows, diff_rows=user_week_rows,
                               first_seen_user_rows=len(users), retention_detail_rows=len(details))
        for name, expected in expected_checks.items():
            check("mysql_" + name, int(mysql_checks.loc[name]), expected, "mysql_readonly_export")
        live_detail = live[live.record_type == "detail"].copy()
        live_detail["first_week"] = pd.to_datetime(live_detail.first_week, dayfirst=True).dt.strftime("%Y-%m-%d")
        check("mysql_exact_detail_row_count", len(live_detail), len(details), "mysql_readonly_export")
        check("mysql_exact_detail_unique_keys", int(live_detail.duplicated(["first_week", "retention_week"]).sum()), 0, "mysql_readonly_export")
        detail_comparison = []
        for _, row in live_detail.iterrows():
            key = (row.first_week, int(row.retention_week))
            expected = lookup.get(key)
            passed = expected is not None and int(row.cohort_users) == expected["count_first"] and int(row.retained_users) == expected["retained_users"] and abs(float(row.retention_rate)-expected["retention_rate"]) < 1e-9
            check(f"mysql_detail_{key[0]}_w{key[1]:02d}", passed, True, "mysql_readonly_export")
            detail_comparison.append(dict(first_week=key[0], retention_week=key[1],
                mysql_cohort_users=int(row.cohort_users), independent_cohort_users=expected["count_first"] if expected else None,
                mysql_retained_users=int(row.retained_users), independent_retained_users=expected["retained_users"] if expected else None,
                mysql_rate=float(row.retention_rate), independent_rate=expected["retention_rate"] if expected else None,
                status="PASS" if passed else "FAIL"))
        pd.DataFrame(detail_comparison).to_csv(OUT / "mysql_detail_comparison.csv", index=False, encoding="utf-8-sig")
        live_overall = live[live.record_type == "overall"].copy()
        check("mysql_overall_row_count", len(live_overall), len(totals), "mysql_readonly_export")
        check("mysql_overall_unique_weeks", int(live_overall.retention_week.duplicated().sum()), 0, "mysql_readonly_export")
        check("mysql_overall_all_weeks_present", sorted(live_overall.retention_week.astype(int).tolist()), list(range(1, max_n + 1)), "mysql_readonly_export")
        mysql_overall_comparison = []
        for _, row in live_overall.iterrows():
            n = int(row.retention_week)
            got = totals[n-1]
            check(f"mysql_overall_week_{n:02d}", bool(
                int(row.cohort_users) == got["first_week_users"] and
                int(row.retained_users) == got["retention_users"] and
                abs(float(row.retention_rate)-got["retention_rate"]) < 1e-9),
                True, "mysql_readonly_export")
            actual_details = live_detail[live_detail.retention_week == n]
            detail_users = int(actual_details.cohort_users.sum())
            detail_retained = int(actual_details.retained_users.sum())
            check(f"mysql_detail_sum_vs_overall_week_{n:02d}_denominator", detail_users, int(row.cohort_users), "mysql_detail_vs_overall")
            check(f"mysql_detail_sum_vs_overall_week_{n:02d}_numerator", detail_retained, int(row.retained_users), "mysql_detail_vs_overall")
            mysql_overall_comparison.append(dict(retention_week=n,
                mysql_overall_users=int(row.cohort_users), mysql_detail_sum_users=detail_users, independent_users=got["first_week_users"],
                mysql_overall_retained=int(row.retained_users), mysql_detail_sum_retained=detail_retained, independent_retained=got["retention_users"],
                mysql_rate=float(row.retention_rate), independent_rate=got["retention_rate"],
                status="PASS" if detail_users==int(row.cohort_users)==got["first_week_users"] and detail_retained==int(row.retained_users)==got["retention_users"] and abs(float(row.retention_rate)-got["retention_rate"])<1e-9 else "FAIL"))
        pd.DataFrame(mysql_overall_comparison).to_csv(OUT / "mysql_overall_comparison.csv", index=False, encoding="utf-8-sig")
        mysql_verified = True

    pd.DataFrame(checks).to_csv(OUT / "validation_checks.csv", index=False, encoding="utf-8-sig")
    manifest = dict(
        started_at_utc=started, completed_at_utc=datetime.now(timezone.utc).isoformat(),
        elapsed_seconds=round(time.perf_counter()-timer, 3),
        scope="全量清洗事件独立重算；MySQL 实际表状态仅在只读结果导出存在时核对",
        source=str(SOURCE.relative_to(ROOT)), source_sha256=sha256(SOURCE),
        source_event_rows=rows, source_observation_start=observed_start, source_observation_end=observed_end,
        distinct_users=int(len(users)), distinct_user_week_rows=int(user_week_rows),
        source_user_week_groups_with_multiple_events=repeated_event_groups,
        source_additional_events_in_same_user_week=extra_events_in_same_user_week,
        rebuilt_user_week_duplicate_keys=0,
        eligible_detail_rows=len(details), eligible_zero_return_cells=int((detail_df.retained_users == 0).sum()),
        matrix_export_sha256=sha256(MATRIX), matrix_cells_checked=len(comparisons),
        matrix_cells_agree=sum(r["status"] == "PASS" for r in comparisons),
        independent_overall_weeks_checked=len(totals),
        visible_mysql_screenshot_weeks_checked=len(screenshot_rows),
        mysql_actual_tables_verified=mysql_verified, mysql_queries_executed_by_agent=False,
        mysql_readonly_export_sha256=sha256(MYSQL_EXPORT) if mysql_verified else None,
        check_count=len(checks), failed_checks=[r for r in checks if r["status"] == "FAIL"],
        snapshot_note="截图数据人工转录，只核对可见第 1～16 周；矩阵只包含已四舍五入百分数。",
        unverified=[] if mysql_verified else [
            "MySQL 实际 tem_user_week_cohort_distinct 和 tem_user_week_cohort_diff 的重复键",
            "MySQL 全部 210 行留存明细的精确回访人数",
            "MySQL 整体第 17～20 周精确人数"
        ]
    )
    manifest["script_sha256"] = sha256(Path(__file__))
    (OUT / "run_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=True, indent=2), flush=True)
    if manifest["failed_checks"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

