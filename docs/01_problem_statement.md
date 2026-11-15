# Problem statement

**Case study 7: cutting unplanned downtime on a machine fleet**
Phase 1 (Ask) · written 15 November 2026

## Stakeholder and question

I am a junior analyst supporting the **maintenance manager** of a plant with 100 machines. Before next year's maintenance budget is set, she asks:

> Where do unplanned failures cost us most, do the machines warn us before they fail, and would replacing parts based on those warnings pay off?

Today the plant runs a mix of **reactive** maintenance (replace a component after it fails) and **scheduled** maintenance (replace components on a fixed routine). The alternative under consideration is **condition-based** maintenance: inspect and replace a component when the machine's own signals say it is about to fail.

## Business task

Find where unplanned failures concentrate, test whether sensor readings and error codes give usable warning before a failure, turn the best warning sign into a simple alert rule, and estimate, with clearly labelled assumptions, whether acting on that alert would cost less than today's approach.

## Questions to answer

| # | Question | How it will be answered |
| --- | --- | --- |
| Q1 | Where do failures concentrate? | Pareto of failures by component, machine model and age group; failures per machine per year |
| Q2 | How reliable is each group? | Mean time between failures (MTBF) by model and component; failure rate against machine age |
| Q3 | Do failures give warning? | Error-code frequency in the 24–48 hours before a failure compared with normal days; sensor drift on control charts with limits from each machine's own baseline |
| Q4 | How good would an alert be? | One simple rule tested against the real failures: share of failures caught (recall), share of alerts that are real (precision), and warning time |
| Q5 | Is it worth it? | Excel model comparing today's reactive + scheduled mix with alert-triggered inspections, with sensitivity and scenarios |

## Decisions this supports

1. **Which components and machine models to watch first**, so monitoring effort goes where failures concentrate.
2. **Whether to pilot an alert rule**, and which one, given how many failures it catches and how many false alarms it creates.
3. **How to set next year's maintenance budget**: the expected saving range from condition-based maintenance, and the cost per downtime hour at which it breaks even.

## Success criteria

- Every number in the findings can be traced to a SQL file or notebook in this repository.
- The alert rule is chosen on January–August data and its final recall and precision are reported on September–December data it has not seen.
- The business case shows a **range** of savings (cautious / base / optimistic) and a sensitivity table, not a single figure.
- The manager gets a one-page summary she can act on: where failures cost most, the proposed alert in one line, and the expected saving range.

## Scope

**In scope:** the five tables of the Azure Predictive Maintenance dataset for 2015; descriptive statistics, Pareto analysis, MTBF, error-window analysis, control charts (statistical process control), evaluation of simple rule-based alerts, an Excel cost model.

**Out of scope:**
- A machine-learning failure-prediction model. A well-tested rule with honest precision and recall is easier to explain and to act on. Stretch goal, only if time allows: the same rule evaluated per component.
- Measuring real downtime or repair time (MTTR): the data has no repair durations.
- Spare-parts inventory, staffing and production scheduling.

## Data and its limits

| Table | Rows | Contents |
| --- | --- | --- |
| machines | 100 | Model (model1–4) and age in years (0–20) |
| telemetry | 876,100 | Hourly voltage, rotation, pressure and vibration per machine, 1 Jan 2015 – 1 Jan 2016 |
| errors | 3,919 | Non-breaking error codes (error1–5) with timestamps |
| maint | 3,286 | Component replacements (comp1–4), scheduled and after failure, June 2014 – January 2016 |
| failures | 761 | Component failures (comp1–4) with timestamps |

Limits to keep in view:

- **Synthetic data.** Results show what the method would reveal on real plant data. The README says so up front.
- **No downtime or cost data.** Downtime hours per failure, cost per downtime hour, part and labour costs are **inputs** in the Excel model, each labelled with its source or reasoning, and tested in a sensitivity table.
- **Coarse failure timestamps.** Almost all failures are logged at 06:00 (743 of 761; the rest at 03:00), so warning time is accurate to about a day.
- **One component failure is not one stoppage.** 761 component failures form 719 failure events; 42 events replaced two components at once.

## Metric definitions

| Metric | Definition |
| --- | --- |
| Component failure | One row in `failures`. Used for the Pareto by component. |
| Failure event | A distinct machine + timestamp in `failures`. Used for failures per machine, MTBF and alert recall. |
| Failures per machine-year | Failure events ÷ machines in the group. Every machine is observed for the full year. |
| MTBF (hours) | Mean hours between consecutive failure events on the same machine (SQL `LAG`). Per component: between consecutive failures of that component on the same machine. The first failure of each machine has no predecessor and is excluded. |
| Age group | 0–5, 6–10, 11–15, 16–20 years. |
| Pre-failure window | The 48 hours before a failure event (24 hours tested as well). |
| Error lift | Errors per machine-day inside pre-failure windows ÷ errors per machine-day outside them. Above 1 means the error is more common before failures. |
| Daily mean signal | 24-hour rolling mean of each sensor reading. Hourly readings are noisy, so control charts and alert rules use this. |
| Control limits | Per machine and sensor: centre line = baseline mean, limits = mean ± 3 standard deviations. The baseline is the first 30 days of 2015, excluding the 7 days before any failure. |
| Alert | The first hour a rule fires. Further firings on the same machine within 7 days count as the same alert. |
| True alert | An alert that fires 0–7 days before a failure event on the same machine. |
| Recall | Failure events with a true alert ÷ all failure events. |
| Precision | True alerts ÷ all alerts. |
| Lead time | Time from the first true alert to the failure (median and range, in days). |
| Scheduled replacement | A `maint` row with no failure on the same machine, hour and component. |
| Reactive replacement | A `maint` row that matches a failure. |

The 24-hour mean, the 7-day windows and the baseline period are starting choices. Alternatives (3- and 14-day windows) will be tested, and the final choice and the reason for it will be reported.
