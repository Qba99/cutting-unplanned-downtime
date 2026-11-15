# Cutting unplanned downtime on a machine fleet

**Where do unplanned failures cost us most, do the machines warn us before they fail, and would replacing parts based on those warnings pay off?**

Work in progress (planned finish: 20 December 2026). Problem statement and metric definitions: [`docs/01_problem_statement.md`](docs/01_problem_statement.md).

## Data

[Microsoft Azure Predictive Maintenance](https://www.kaggle.com/datasets/arnabbiswas1/microsoft-azure-predictive-maintenance) on Kaggle: 100 machines, one year (2015), five tables. **The data is synthetic.** Findings show what this method would reveal on real plant data, not facts about a real plant.

To reproduce, download the five CSVs into `data/raw/` (they are not committed; telemetry is 80 MB).

## How to reproduce

Needs Python 3.10+ and PostgreSQL 13+ (built and tested on PostgreSQL 16).

```bash
python -m venv .venv && .venv\Scripts\activate   # Windows; on macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt

# download the five CSVs from Kaggle into data/raw/, then:
python src/load_db.py      # creates the database, loads the tables, builds the views, runs the checks
python src/export_views.py # writes the analysis views to data/exports/*.csv for Excel and the notebooks
```

`load_db.py` reads the standard `PGHOST`/`PGPORT`/`PGUSER` variables and asks for the password, which is never written to disk. It loads the 876,100 telemetry rows with `COPY` in about 15 seconds, then writes the data-quality results to [`docs/02_data_quality_log.md`](docs/02_data_quality_log.md). After editing any SQL file, `python src/load_db.py --views-only` rebuilds the views without reloading the data.

## Repository layout

| Folder | Contents |
| --- | --- |
| `data/raw/` | The five Kaggle CSVs, untouched (not committed) |
| `data/exports/` | Small CSVs exported from SQL and Python for Excel |
| `sql/` | Table creation, loading, data-quality checks and analysis queries |
| `notebooks/` | EDA, control charts, alert-rule evaluation |
| `src/` | Shared Python helpers |
| `images/` | Charts used in this README and the summary |
| `excel/` | Business-case workbook |
| `docs/` | Problem statement, data-quality log, one-page summary |
