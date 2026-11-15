# SQL findings (Phase 4a)

Results of `sql/04_pareto.sql`, `sql/05_mtbf.sql` and `sql/06_error_windows.sql` on the 2015 data. The CSV behind every number is in `data/exports/`. These notes feed the README findings later; the data is synthetic.

## Q1: Where do failures concentrate?

**Two components cause 59% of component failures; model1 and model2 machines fail almost twice as often as model3 and model4.**

| Component | Failures | % | Cumulative % |
| --- | ---: | ---: | ---: |
| comp2 | 259 | 34.0 | 34.0 |
| comp1 | 192 | 25.2 | 59.3 |
| comp4 | 179 | 23.5 | 82.8 |
| comp3 | 131 | 17.2 | 100.0 |

| Model | Machines | Failure events | Events per machine | % of fleet | % of events |
| --- | ---: | ---: | ---: | ---: | ---: |
| model1 | 16 | 175 | 10.9 | 16 | 24.3 |
| model2 | 17 | 160 | 9.4 | 17 | 22.3 |
| model3 | 35 | 212 | 6.1 | 35 | 29.5 |
| model4 | 32 | 172 | 5.4 | 32 | 23.9 |

- model1 and model2 are a third of the fleet but cause 47% of failure events.
- **comp3 fails only on model1 and model2** (131 failures, none on model3 or model4). It is these models' most frequent failure: one every 86–98 days per machine.
- The model gap is **not** explained by age: average age is similar (12.3 and 12.8 vs 12.0 and 9.3 years), and model1/model2 fail more often than model3/model4 inside every age group (`v_model_age_crosstab`).

## Q2: How reliable is each group?

**MTBF is 33 days for a model1 machine and 68 days for a model4 machine. Older machines fail more often, within every model.**

| Model | MTBF (days) | Median gap between failures (days) |
| --- | ---: | ---: |
| model1 | 33.4 | 30 |
| model2 | 38.8 | 30 |
| model3 | 60.3 | 45 |
| model4 | 67.9 | 45 |

- By component (fleet-wide, per machine): comp2 fails every 141 days, comp1 every 190, comp4 every 204, comp3 every 279.
- Age and failures: correlation 0.46 across all machines; each extra year of age adds about 0.26 failures a year. The correlation stays between 0.39 and 0.54 inside each model, so age and model are separate effects.
- Machines aged 16–20 are 29% of the fleet and cause 37% of failure events (9.1 per machine vs 5.2–5.7 for machines up to 10 years old).
- 604 of 621 gaps between failures are exact multiples of 15 days (median 30 or 45). Real plants are not this regular, which is a sign of the synthetic data.

## Q3, part 1: Do error codes warn before a failure?

**Yes, strongly. Each component has its own warning code, and 96–99% of its failures have that code in the 48 hours before.**

| Failing component | Warning code | Failures with that code in the 48 h before | Lift |
| --- | --- | ---: | ---: |
| comp1 | error1 | 95.8% | 23 |
| comp2 | error2 and error3 | 98.8% (each) | 25 and 33 |
| comp3 | error4 | 97.7% | 31 |
| comp4 | error5 | 98.3% | 102 |

- The 48 hours before failures cover 3.9% of machine-hours but hold 28.7% of all errors (lift 10). In the 24 hours before, the lift is 19.
- 705 of 719 failure events (98%) had at least one error in the 48 hours before. The first error came a median of 24 hours before the failure. Failures are logged once a day, so read this as "about a day of notice".
- **The catch: most errors are not followed by a failure.** 2,796 of 3,919 errors (71%) came outside any pre-failure window. An alert on "any error" would catch almost every failure but produce many false alarms. Phase 4b measures this trade-off (precision vs recall) and compares it with sensor-based rules.
