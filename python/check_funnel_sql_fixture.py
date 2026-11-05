#!/usr/bin/env python
"""Exercise archived SQL on an explicitly synthetic SQLite fixture.
This adapts MySQL syntax to SQLite ONLY for logic checks; it is not MySQL
syntax/runtime certification. Full-data numbers are checked by 03_validate_funnel_results.py.
"""
import hashlib
import json
import math
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOW = 604800
BASE = 1569888000
END = 1583020799
CUTOFF = END - WINDOW


def timestamp(value):
    return datetime.fromtimestamp(value, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def adapt(sql):
    sql = re.sub(r"(?m)--[^\n]*|#[^\n]*", "", sql)
    sql = re.sub(r"ENGINE\s*=\s*InnoDB", "", sql, flags=re.I)
    sql = re.sub(r"TIMESTAMPDIFF\s*\(\s*SECOND\s*,", "seconds_between(", sql, flags=re.I)
    sql = re.sub(r"UTC_TIMESTAMP\s*\(\s*6\s*\)", "datetime('now')", sql, flags=re.I)
    sql = re.sub(r"date_sub\s*\(\s*max\(event_time\)\s*,\s*INTERVAL\s+7\s+DAY\s*\)",
                 "datetime(max(event_time), '-7 days')", sql, flags=re.I)
    sql = re.sub(r"(\b[\w.]+)\s*\+\s*INTERVAL\s+7\s+DAY",
                 r"datetime(\1, '+7 days')", sql, flags=re.I)
    sql = re.sub(r"CAST\s*\(\s*('.*?')\s+AS\s+DATETIME\s*\)", r"\1", sql, flags=re.I)
    sql = re.sub(r"('.*?')\s*([+-])\s*INTERVAL\s+7\s+DAY",
                 lambda m: f"datetime({m[1]}, '{m[2]}7 days')", sql, flags=re.I)
    sql = sql.replace("<=>", " IS ")
    # MySQL integer operands use decimal division; SQLite needs an explicit real operand.
    sql = sql.replace("/", "* 1.0 /")
    return [s.strip() for s in sql.split(";") if s.strip()
            and not s.strip().lower().startswith("use ")]


def main():
    b = BASE + 100
    rows = [
        (1,10,b,1), (1,10,b,2), (1,10,b+1,2), (1,10,b+1,4), (1,10,b+2,4),
        (2,10,CUTOFF,1), (2,10,CUTOFF+1,2), (2,10,END,4),
        (3,10,CUTOFF+1,1), (3,10,CUTOFF+2,2), (3,10,END,4),
        (4,10,b,1), (4,10,b+WINDOW,2), (4,10,b+WINDOW+1,4),
        (5,10,b-50,2), (5,10,b-40,4), (5,10,b,1),
        (5,10,b+1,4), (5,10,b+2,2), (5,10,b+3,4),
        (6,10,b,1), (6,10,b+WINDOW,1), (6,10,b+WINDOW+1,2), (6,10,b+WINDOW+2,4),
        (7,10,b,1), (7,10,b+1,2), (7,10,b+2,4),
        (7,20,b,1), (7,20,b+1,2), (7,20,b+2,4),
        (8,10,b,2), (8,10,b+1,4),
        (9,10,b,1), (9,10,b+1,2), (9,10,b+100,4),
        (9,20,b+98,1), (9,20,b+99,2), (9,20,b+101,4),
    ]
    con = sqlite3.connect(":memory:")
    con.create_function("CEIL", 1, math.ceil)
    con.create_function("IF", 3, lambda condition, yes, no: yes if condition else no)
    con.create_function("seconds_between", 2, lambda start, end:
                        int((datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds())
                        if start and end else None)
    con.execute("""CREATE TABLE events (event_time TEXT, event_type TEXT, product_id INTEGER,
                category_id INTEGER, price REAL, user_id INTEGER, user_session TEXT)""")
    labels = {1: "view", 2: "cart", 4: "purchase"}
    con.executemany("INSERT INTO events VALUES (?,?,?,?,?,?,?)",
                    [(timestamp(t), labels[c], p, 1, 1.0, u, None) for u,p,t,c in rows])
    counts, structural_results, quantiles = {}, [], None
    hashes = {}
    for filename in ("02_import_validation.sql", "04_funnel_user_product.sql",
                     "05_funnel_metrics.sql", "06_funnel_validation.sql"):
        path = ROOT / "sql" / filename
        raw = path.read_text(encoding="utf-8")
        hashes[filename] = hashlib.sha256(path.read_bytes()).hexdigest()
        assert chr(0xff1b) not in re.sub(r'(?m)--[^\n]*|#[^\n]*', '', raw)
        queries = adapt(raw)
        counts[filename] = len(queries)
        for query in queries:
            try:
                cursor = con.execute(query)
            except sqlite3.Error as exc:
                raise RuntimeError(f"{filename}: {exc}\n{query}") from exc
            if cursor.description:
                names = [col[0] for col in cursor.description]
                result = cursor.fetchall()
                if names == ["median", "p75", "p90", "p95"]:
                    quantiles = result[0]
                for row in result:
                    for name, value in zip(names, row):
                        if name.startswith(("invalid_", "duplicate_")):
                            assert value == 0, (filename, name, value)
                            structural_results.append(name)
    assert con.execute("SELECT * FROM tem_funnel_a").fetchone() == (8,8,8,8)
    assert con.execute("""SELECT COUNT(*), SUM(reached_cart_7d_cn),
        SUM(reached_view_purchase_7d_cn), SUM(reached_strict_purchase_7d_cn)
        FROM tem_funnel_7d_user""").fetchone() == (7,6,5,5)
    assert con.execute("SELECT time_step FROM tem_user_first_strict WHERE user_id=9").fetchone() == (100,)
    assert quantiles == (100,604800,604802,604802), quantiles
    assert con.execute("""SELECT SUM(time_step<=86400), SUM(time_step<=604800),
        SUM(time_step<=1209600), SUM(time_step<=2592000)
        FROM tem_user_first_strict""").fetchone() == (4,6,8,8)
    assert con.execute("""SELECT reached_strict_purchase_7d FROM tem_funnel_7d_path
        WHERE user_id=2""").fetchone() == (1,)
    assert con.execute("SELECT COUNT(*) FROM tem_funnel_7d_path WHERE user_id=3").fetchone() == (0,)
    assert con.execute("SELECT reached_cart_7d FROM tem_funnel_7d_path WHERE user_id=6").fetchone() == (0,)
    result = {
        "status": "passed", "executed_at_utc": datetime.now(timezone.utc).isoformat(),
        "fixture": "synthetic 9-user timestamp-boundary controls; NOT actual REES46 users",
        "engine": "SQLite " + sqlite3.sqlite_version,
        "adaptations": ["remove ENGINE/USE", "adapt datetime functions and INTERVAL",
                        "register IF and second-difference", "null-safe equality", "real division"],
        "scope": "archived SQL logic on synthetic data after dialect adaptation; MySQL not executed",
        "statements_exercised": counts, "structural_zero_results": structural_results,
        "expected_no_window_counts": [8,8,8,8],
        "expected_7d_counts": [7,6,5,5],
        "expected_quantiles_seconds": list(quantiles),
        "sql_sha256": hashes, "mysql_executed": False
    }
    output = ROOT / "data/analysis_output/funnel_20260922/verification/sql_fixture_check.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "passed", "statements": counts,
                      "note": "Synthetic adapted SQLite check; not MySQL execution."}))


if __name__ == "__main__":
    main()

