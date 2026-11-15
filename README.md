# Cutting unplanned downtime on a machine fleet

**Where do unplanned failures cost us most, do the machines warn us before they fail, and would replacing parts based on those warnings pay off?**

Work in progress (planned finish: 20 December 2026). Problem statement and metric definitions: [`docs/01_problem_statement.md`](docs/01_problem_statement.md).

## Data

[Microsoft Azure Predictive Maintenance](https://www.kaggle.com/datasets/arnabbiswas1/microsoft-azure-predictive-maintenance) on Kaggle: 100 machines, one year (2015), five tables. **The data is synthetic.** Findings show what this method would reveal on real plant data, not facts about a real plant.

To reproduce, download the five CSVs into `data/raw/` (they are not committed; telemetry is 80 MB).

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
