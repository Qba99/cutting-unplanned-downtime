"""Phase 2: load the Kaggle CSVs into PostgreSQL, build the views, check the data.

1. creates the database if it does not exist yet (default name: predictive_maintenance)
2. runs sql/01_create_tables.sql (drops and recreates the tables, so re-runs are safe)
3. bulk-loads data/raw/PdM_*.csv with COPY and checks each table against its CSV
4. builds the views: every sql/NN_*.sql file after 01, in order (02 clean views,
   03 data-quality checks, and later the analysis files 04, 05, ...)
5. runs the data-quality checks (v_data_quality), prints them and writes
   docs/02_data_quality_log.md

Connection settings come from the usual PostgreSQL environment variables
(PGHOST, PGPORT, PGUSER, PGPASSWORD) or the options below. If no password is set,
you are asked for it; it is never written to disk.

Usage (from the repo root):
    python src/load_db.py
    python src/load_db.py --user postgres --dbname predictive_maintenance
    python src/load_db.py --views-only     # rebuild the views and re-run the checks, no reload
Exits with code 1 if any check FAILs.
"""
from __future__ import annotations

import argparse
import csv
import getpass
import os
import sys
import time
from datetime import datetime
from pathlib import Path

import psycopg2
from psycopg2 import sql

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = REPO_ROOT / "data" / "raw"
SQL_DIR = REPO_ROOT / "sql"
SCHEMA_FILE = SQL_DIR / "01_create_tables.sql"
DQ_LOG = REPO_ROOT / "docs" / "02_data_quality_log.md"

# table -> (CSV file, table columns in the CSV's column order). Load order respects
# the foreign keys: machines first.
TABLES = {
    "machines":  ("PdM_machines.csv",  ["machine_id", "model", "age"]),
    "telemetry": ("PdM_telemetry.csv", ["datetime", "machine_id", "volt", "rotate", "pressure", "vibration"]),
    "errors":    ("PdM_errors.csv",    ["datetime", "machine_id", "error_id"]),
    "maint":     ("PdM_maint.csv",     ["datetime", "machine_id", "comp"]),
    "failures":  ("PdM_failures.csv",  ["datetime", "machine_id", "comp"]),
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dbname", default="predictive_maintenance")
    p.add_argument("--host", default=os.getenv("PGHOST", "localhost"))
    p.add_argument("--port", default=os.getenv("PGPORT", "5432"))
    p.add_argument("--user", default=os.getenv("PGUSER", "postgres"))
    p.add_argument("--password", default=os.getenv("PGPASSWORD"))
    p.add_argument("--views-only", action="store_true",
                   help="skip the table load; rebuild the views and re-run the checks")
    args = p.parse_args()
    if args.password is None:
        args.password = getpass.getpass(f"PostgreSQL password for {args.user}: ")
    return args


def connect(args, dbname: str):
    return psycopg2.connect(host=args.host, port=args.port, user=args.user,
                            password=args.password, dbname=dbname, client_encoding="UTF8")


def ensure_database(args) -> None:
    """CREATE DATABASE cannot run inside a transaction, so use autocommit."""
    conn = connect(args, "postgres")
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (args.dbname,))
        if cur.fetchone() is None:
            cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(args.dbname)))
            print(f"Created database {args.dbname}")
        else:
            print(f"Using existing database {args.dbname}")
    conn.close()


def csv_rows(path: Path) -> int:
    """Data rows in a CSV (header excluded)."""
    with open(path, encoding="utf-8", newline="") as fh:
        return sum(1 for _ in csv.reader(fh)) - 1


def load_tables(conn) -> None:
    missing = [f for f, _ in TABLES.values() if not (RAW_DIR / f).exists()]
    if missing:
        sys.exit(f"Missing in {RAW_DIR}: {', '.join(missing)}. Download them from Kaggle first.")

    with conn.cursor() as cur:
        print(f"Running {SCHEMA_FILE.name}")
        cur.execute(SCHEMA_FILE.read_text(encoding="utf-8"))
        for table, (filename, columns) in TABLES.items():
            path = RAW_DIR / filename
            started = time.perf_counter()
            copy = sql.SQL("COPY {} ({}) FROM STDIN WITH (FORMAT csv, HEADER true)").format(
                sql.Identifier(table), sql.SQL(", ").join(map(sql.Identifier, columns)))
            with open(path, encoding="utf-8", newline="") as fh:
                cur.copy_expert(copy.as_string(conn), fh)
            cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(table)))
            loaded, expected = cur.fetchone()[0], csv_rows(path)
            status = "OK" if loaded == expected else "MISMATCH"
            print(f"  {table:<10} {loaded:>9,} rows  (CSV: {expected:,})  {status}"
                  f"  {time.perf_counter() - started:.1f}s")
            if loaded != expected:
                raise RuntimeError(f"{table}: loaded {loaded} rows but the CSV has {expected}")
    conn.commit()
    # fresh statistics so the planner picks good plans for the window joins later
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("ANALYZE")
    conn.autocommit = False


def build_views(conn) -> None:
    files = sorted(f for f in SQL_DIR.glob("[0-9][0-9]_*.sql") if f.name > SCHEMA_FILE.name)
    with conn.cursor() as cur:
        for f in files:
            print(f"Running {f.name}")
            cur.execute(f.read_text(encoding="utf-8"))
    conn.commit()


def run_checks(conn) -> list[tuple]:
    with conn.cursor() as cur:
        cur.execute("SELECT check_id, area, check_name, expected, actual, result "
                    "FROM v_data_quality ORDER BY check_id")
        return cur.fetchall()


def write_log(rows: list[tuple], dbname: str) -> None:
    hard = [r for r in rows if r[5] in ("PASS", "FAIL")]
    passed = sum(r[5] == "PASS" for r in hard)
    lines = [
        "# Data quality log",
        "",
        f"Generated by `src/load_db.py` on {datetime.now():%Y-%m-%d %H:%M} from the database "
        f"`{dbname}`. The checks live in `sql/03_data_quality.sql` (view `v_data_quality`).",
        "",
        f"**{passed} of {len(hard)} checks passed.** PASS/FAIL rows are rules the data must meet; "
        "INFO rows are facts that shape the analysis. Nulls and duplicate rows are blocked by "
        "NOT NULL constraints and primary keys, so a successful load has none.",
        "",
        "| ID | Area | Check | Expected | Actual | Result |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    lines += [f"| {r[0]} | {r[1]} | {r[2]} | {r[3]} | {r[4]} | {r[5]} |" for r in rows]
    lines += [
        "",
        "## What the INFO rows mean for the analysis",
        "",
        "| Finding | Decision |",
        "| --- | --- |",
        "| Two components can fail in the same event (DQ16) | Component Pareto counts component failures; "
        "failures per machine, MTBF and alert recall count failure events (`v_failure_events`). |",
        "| Almost every failure is logged at 06:00 (DQ14) | Warning time is accurate to about a day; "
        "report it in days. |",
        "| A few failures have no same-day replacement, all at one timestamp (DQ17) | Kept as failures; "
        "looks like an artefact of how the synthetic data was generated. Noted in the README. |",
        "| maint starts in June 2014 (DQ15) | Rows before 2015 are kept for days since the previous "
        "replacement, but excluded from 2015 counts and costs (`in_2015`). |",
        "| Scheduled vs after-failure replacements (DQ18) | Feeds the current-state cost in the Excel model. |",
        "| Sensor outliers (DQ11) | Kept: unusual readings before failures are what the analysis looks for. |",
        "",
    ]
    DQ_LOG.parent.mkdir(parents=True, exist_ok=True)
    DQ_LOG.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    args = parse_args()
    ensure_database(args)
    conn = connect(args, args.dbname)
    try:
        if not args.views_only:
            load_tables(conn)
        build_views(conn)
        rows = run_checks(conn)
    finally:
        conn.close()

    print("\nData-quality checks")
    for r in rows:
        print(f"  {r[5]:<4}  {r[0]}  {r[2]}: {r[4]}")
    write_log(rows, args.dbname)
    print(f"\nWrote {DQ_LOG.relative_to(REPO_ROOT)}")

    failed = [r for r in rows if r[5] == "FAIL"]
    if failed:
        print(f"\n{len(failed)} check(s) FAILED: {', '.join(r[0] for r in failed)}")
        sys.exit(1)
    print("\nAll PASS/FAIL checks passed.")


if __name__ == "__main__":
    main()
