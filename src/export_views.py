"""Export the analysis views to data/exports/*.csv (small files, committed to the repo).

Excel (Power Query) and the notebooks read these CSVs, so neither needs a database
connection, and anyone can rerun the analysis from the repo alone.

Usage (from the repo root, after src/load_db.py):
    python src/export_views.py
Connection settings: same as load_db.py (PGHOST, PGPORT, PGUSER, PGPASSWORD or prompt).
"""
from __future__ import annotations

import argparse
import csv
import getpass
import os
from pathlib import Path

import psycopg2
from psycopg2 import sql

REPO_ROOT = Path(__file__).resolve().parents[1]
EXPORT_DIR = REPO_ROOT / "data" / "exports"

# view -> what it answers (printed as a reminder; the file name is the view name)
VIEWS = {
    "v_data_quality":            "data-quality checks",
    "v_pareto_component":        "Q1 failures by component",
    "v_pareto_model":            "Q1 failure events by model",
    "v_pareto_age_group":        "Q1 failure events by age group",
    "v_failures_per_machine":    "Q1 one row per machine",
    "v_model_age_crosstab":      "Q1 model x age group",
    "v_mtbf_by_model":           "Q2 MTBF by model",
    "v_mtbf_by_component":       "Q2 MTBF by component",
    "v_mtbf_by_model_component": "Q2 MTBF by model x component",
    "v_age_failure_rate":        "Q2 failures by age in years",
    "v_age_correlation":         "Q2 age vs failures",
    "v_failure_intervals":       "Q2 gaps between failure events",
    "v_error_window_lift":       "Q3 error lift before failures",
    "v_error_component_lift":    "Q3 error lift by failing component",
    "v_failure_warning":         "Q3 errors before each failure event",
    "v_maint_typed":             "Q5 replacements, scheduled vs after failure",
}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dbname", default="predictive_maintenance")
    p.add_argument("--host", default=os.getenv("PGHOST", "localhost"))
    p.add_argument("--port", default=os.getenv("PGPORT", "5432"))
    p.add_argument("--user", default=os.getenv("PGUSER", "postgres"))
    p.add_argument("--password", default=os.getenv("PGPASSWORD"))
    args = p.parse_args()
    if args.password is None:
        args.password = getpass.getpass(f"PostgreSQL password for {args.user}: ")

    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    conn = psycopg2.connect(host=args.host, port=args.port, user=args.user,
                            password=args.password, dbname=args.dbname, client_encoding="UTF8")
    total = 0
    try:
        with conn.cursor() as cur:
            for view, label in VIEWS.items():
                cur.execute(sql.SQL("SELECT * FROM {}").format(sql.Identifier(view)))
                header = [d[0] for d in cur.description]
                rows = cur.fetchall()
                path = EXPORT_DIR / f"{view}.csv"
                with open(path, "w", encoding="utf-8", newline="") as fh:
                    w = csv.writer(fh)
                    w.writerow(header)
                    w.writerows(rows)
                size = path.stat().st_size
                total += size
                print(f"  {path.name:<34} {len(rows):>6,} rows  {size / 1024:>6.1f} KB   {label}")
    finally:
        conn.close()
    print(f"\nWrote {len(VIEWS)} files to {EXPORT_DIR.relative_to(REPO_ROOT)} ({total / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
