-- 05_mtbf.sql
-- Q2: How reliable is each group, and do older machines fail more often?
--
-- v_failure_intervals        one row per failure event: hours since the machine's previous failure
-- v_component_intervals      one row per component failure: hours since that component last failed
-- v_mtbf_by_model            MTBF per machine model
-- v_mtbf_by_component        MTBF per component (fleet-wide)
-- v_mtbf_by_model_component  MTBF per model x component (the hotspots)
-- v_age_failure_rate         failure events per machine for each age in years
-- v_age_correlation          correlation of age with failures, overall and within each model
--
-- Two MTBF measures, reported side by side:
--   mtbf_hours          = operating hours / failures. The standard reliability definition;
--                         uses every machine-hour, including machines that failed once or never.
--   mean_gap_hours      = mean of the gaps between consecutive failures on the same machine
--                         (SQL LAG). Closer to "how long a repaired machine runs"; the time
--                         before each machine's first failure and after its last is not a gap
--                         (censored), so it is biased towards short gaps.
-- Operating hours = every machine is observed for the whole telemetry period (8,760 hours).

DROP VIEW IF EXISTS v_age_correlation          CASCADE;
DROP VIEW IF EXISTS v_age_failure_rate         CASCADE;
DROP VIEW IF EXISTS v_mtbf_by_model_component  CASCADE;
DROP VIEW IF EXISTS v_mtbf_by_component        CASCADE;
DROP VIEW IF EXISTS v_mtbf_by_model            CASCADE;
DROP VIEW IF EXISTS v_component_intervals      CASCADE;
DROP VIEW IF EXISTS v_failure_intervals        CASCADE;
DROP VIEW IF EXISTS v_observed_hours           CASCADE;

-- Hours each machine is observed (one value, from the telemetry period).
CREATE VIEW v_observed_hours AS
SELECT EXTRACT(EPOCH FROM MAX(datetime) - MIN(datetime)) / 3600.0 AS hours_per_machine
FROM telemetry;

CREATE VIEW v_failure_intervals AS
SELECT e.machine_id,
       m.model,
       e.datetime,
       e.components,
       LAG(e.datetime) OVER w                                              AS prev_failure,
       EXTRACT(EPOCH FROM e.datetime - LAG(e.datetime) OVER w) / 3600.0    AS hours_since_prev
FROM v_failure_events e
JOIN v_machines m USING (machine_id)
WINDOW w AS (PARTITION BY e.machine_id ORDER BY e.datetime);

CREATE VIEW v_component_intervals AS
SELECT f.machine_id,
       m.model,
       f.comp,
       f.datetime,
       LAG(f.datetime) OVER w                                              AS prev_failure,
       EXTRACT(EPOCH FROM f.datetime - LAG(f.datetime) OVER w) / 3600.0    AS hours_since_prev
FROM failures f
JOIN v_machines m USING (machine_id)
WINDOW w AS (PARTITION BY f.machine_id, f.comp ORDER BY f.datetime);

CREATE VIEW v_mtbf_by_model AS
SELECT p.model,
       p.machines,
       p.failure_events,
       ROUND((p.machines * o.hours_per_machine / NULLIF(p.failure_events, 0))::numeric, 0)   AS mtbf_hours,
       ROUND((p.machines * o.hours_per_machine / NULLIF(p.failure_events, 0) / 24)::numeric, 1) AS mtbf_days,
       g.gaps,
       ROUND(g.mean_gap_hours::numeric, 0)                                                AS mean_gap_hours,
       ROUND(g.median_gap_hours::numeric, 0)                                              AS median_gap_hours
FROM v_pareto_model p
CROSS JOIN v_observed_hours o
LEFT JOIN (SELECT model,
                  COUNT(hours_since_prev)                                         AS gaps,
                  AVG(hours_since_prev)                                           AS mean_gap_hours,
                  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_since_prev)   AS median_gap_hours
           FROM v_failure_intervals
           GROUP BY model) g USING (model)
ORDER BY mtbf_hours;

-- Fleet-wide: how long, on average, until one machine's comp X fails.
CREATE VIEW v_mtbf_by_component AS
SELECT c.comp,
       c.failures,
       ROUND((100 * o.hours_per_machine / c.failures)::numeric, 0)          AS mtbf_hours,
       ROUND((100 * o.hours_per_machine / c.failures / 24)::numeric, 1)     AS mtbf_days,
       g.gaps,
       ROUND(g.mean_gap_hours::numeric, 0)                                  AS mean_gap_hours,
       ROUND(g.median_gap_hours::numeric, 0)                                AS median_gap_hours
FROM v_pareto_component c
CROSS JOIN v_observed_hours o
LEFT JOIN (SELECT comp,
                  COUNT(hours_since_prev)                                         AS gaps,
                  AVG(hours_since_prev)                                           AS mean_gap_hours,
                  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY hours_since_prev)   AS median_gap_hours
           FROM v_component_intervals
           GROUP BY comp) g USING (comp)
ORDER BY mtbf_hours;

-- Per machine of a model: how long until comp X fails. Days, for readability.
CREATE VIEW v_mtbf_by_model_component AS
SELECT m.model,
       m.machines,
       c.comp,
       COALESCE(f.failures, 0)                                                         AS failures,
       ROUND((m.machines * o.hours_per_machine / NULLIF(f.failures, 0) / 24)::numeric, 0) AS mtbf_days,
       ROUND(COALESCE(f.failures, 0)::numeric / m.machines, 2)                          AS failures_per_machine
FROM (SELECT model, COUNT(*) AS machines FROM machines GROUP BY model) m
CROSS JOIN (VALUES ('comp1'), ('comp2'), ('comp3'), ('comp4')) AS c(comp)
CROSS JOIN v_observed_hours o
LEFT JOIN (SELECT mm.model, f.comp, COUNT(*) AS failures
           FROM failures f JOIN machines mm USING (machine_id)
           GROUP BY mm.model, f.comp) f USING (model, comp)
ORDER BY m.model, c.comp;

CREATE VIEW v_age_failure_rate AS
SELECT age,
       COUNT(*)                          AS machines,
       SUM(failure_events)               AS failure_events,
       ROUND(AVG(failure_events), 2)     AS events_per_machine
FROM v_failures_per_machine
GROUP BY age
ORDER BY age;

-- Pearson correlation of age with failure events per machine, and the slope
-- (extra failures per machine per extra year of age). Within-model rows remove
-- the model effect: if they stay near zero, age is not the driver.
CREATE VIEW v_age_correlation AS
SELECT 'all machines' AS scope,
       COUNT(*)                                                   AS machines,
       ROUND(CORR(failure_events, age)::numeric, 2)               AS corr_age_failures,
       ROUND(REGR_SLOPE(failure_events, age)::numeric, 3)         AS extra_failures_per_year
FROM v_failures_per_machine
UNION ALL
SELECT model,
       COUNT(*),
       ROUND(CORR(failure_events, age)::numeric, 2),
       ROUND(REGR_SLOPE(failure_events, age)::numeric, 3)
FROM v_failures_per_machine
GROUP BY model;
