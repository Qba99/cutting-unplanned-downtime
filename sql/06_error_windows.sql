-- 06_error_windows.sql
-- Q3 (part 1): Do error codes warn before a failure?
--
-- mv_hour_flags          materialized view: one row per machine-hour, flagged when it falls in
--                        the 24 h / 48 h before a failure (any component, and per component)
-- v_error_window_lift    errors per machine-day inside vs outside pre-failure windows, per error type
-- v_error_component_lift the same per error type x failing component, plus the share of that
--                        component's failures with at least one such error in the 48 h before
-- v_failure_warning      one row per failure event: which errors came in the 48 h before, and
--                        how many hours before the failure the first one appeared
--
-- Window: an hour h is "before a failure" when a failure on the same machine happens in
-- (h, h + window], i.e. the window is [failure - window, failure). Errors logged in the
-- failure hour itself (3 of 3,919) are not counted as warning.
-- Lift = rate inside windows / rate outside ALL pre-failure windows. Lift 1 = no signal.
-- Exposure is counted in real machine-hours, so overlapping windows are not double-counted.

DROP VIEW IF EXISTS v_failure_warning      CASCADE;
DROP VIEW IF EXISTS v_error_component_lift CASCADE;
DROP VIEW IF EXISTS v_error_window_lift    CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_hour_flags CASCADE;

CREATE MATERIALIZED VIEW mv_hour_flags AS
SELECT t.machine_id,
       t.datetime,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '24 hours') AS pre_24h,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '48 hours') AS pre_48h,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id AND f.comp = 'comp1'
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '48 hours') AS pre_48h_comp1,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id AND f.comp = 'comp2'
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '48 hours') AS pre_48h_comp2,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id AND f.comp = 'comp3'
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '48 hours') AS pre_48h_comp3,
       EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = t.machine_id AND f.comp = 'comp4'
                 AND f.datetime > t.datetime AND f.datetime <= t.datetime + INTERVAL '48 hours') AS pre_48h_comp4
FROM telemetry t;

CREATE UNIQUE INDEX idx_hour_flags ON mv_hour_flags (machine_id, datetime);

CREATE VIEW v_error_window_lift AS
WITH hours AS (   -- machine-hours of exposure, per window
    SELECT w.window_hours,
           COUNT(*) FILTER (WHERE w.inside)      AS hours_inside,
           COUNT(*) FILTER (WHERE NOT w.inside)  AS hours_outside
    FROM mv_hour_flags h
    CROSS JOIN LATERAL (VALUES (24, h.pre_24h), (48, h.pre_48h)) AS w(window_hours, inside)
    GROUP BY w.window_hours
),
errs AS (         -- errors per type (plus 'any error'), per window
    SELECT w.window_hours,
           COALESCE(e.error_id, 'any error')     AS error_id,
           COUNT(*) FILTER (WHERE w.inside)      AS errors_inside,
           COUNT(*) FILTER (WHERE NOT w.inside)  AS errors_outside
    FROM errors e
    JOIN mv_hour_flags h USING (machine_id, datetime)
    CROSS JOIN LATERAL (VALUES (24, h.pre_24h), (48, h.pre_48h)) AS w(window_hours, inside)
    GROUP BY w.window_hours, ROLLUP (e.error_id)
)
SELECT e.window_hours,
       e.error_id,
       e.errors_inside,
       e.errors_outside,
       ROUND(100.0 * e.errors_inside / (e.errors_inside + e.errors_outside), 1)        AS pct_of_errors_inside,
       ROUND(100.0 * h.hours_inside / (h.hours_inside + h.hours_outside), 1)           AS pct_of_hours_inside,
       ROUND(e.errors_inside  / (h.hours_inside  / 24.0), 4)                           AS per_machine_day_inside,
       ROUND(e.errors_outside / (h.hours_outside / 24.0), 4)                           AS per_machine_day_outside,
       ROUND((e.errors_inside::numeric / h.hours_inside)
             / NULLIF(e.errors_outside::numeric / h.hours_outside, 0), 1)              AS lift
FROM errs e
JOIN hours h USING (window_hours)
ORDER BY e.window_hours, e.error_id;

CREATE VIEW v_error_component_lift AS
WITH flags AS (
    SELECT h.machine_id, h.datetime, h.pre_48h, c.comp, c.inside
    FROM mv_hour_flags h
    CROSS JOIN LATERAL (VALUES ('comp1', h.pre_48h_comp1), ('comp2', h.pre_48h_comp2),
                               ('comp3', h.pre_48h_comp3), ('comp4', h.pre_48h_comp4)) AS c(comp, inside)
),
hours AS (
    SELECT comp,
           COUNT(*) FILTER (WHERE inside)        AS hours_inside,
           COUNT(*) FILTER (WHERE NOT pre_48h)   AS hours_outside     -- outside ALL windows
    FROM flags
    GROUP BY comp
),
errs AS (
    SELECT f.comp, e.error_id,
           COUNT(*) FILTER (WHERE f.inside)      AS errors_inside,
           COUNT(*) FILTER (WHERE NOT f.pre_48h) AS errors_outside
    FROM errors e
    JOIN flags f USING (machine_id, datetime)
    GROUP BY f.comp, e.error_id
),
preceded AS (     -- share of comp X failures with at least one error_id in the 48 h before
    SELECT f.comp, et.error_id,
           COUNT(*)                                                       AS failures,
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM errors e
               WHERE e.machine_id = f.machine_id AND e.error_id = et.error_id
                 AND e.datetime >= f.datetime - INTERVAL '48 hours' AND e.datetime < f.datetime
           ))                                                             AS failures_with_error
    FROM failures f
    CROSS JOIN (SELECT DISTINCT error_id FROM errors) et
    GROUP BY f.comp, et.error_id
)
SELECT p.comp,
       p.error_id,
       p.failures,
       p.failures_with_error,
       ROUND(100.0 * p.failures_with_error / p.failures, 1)                            AS pct_failures_with_error,
       COALESCE(e.errors_inside, 0)                                                    AS errors_inside,
       ROUND((COALESCE(e.errors_inside, 0)::numeric / h.hours_inside)
             / NULLIF(COALESCE(e.errors_outside, 0)::numeric / h.hours_outside, 0), 1) AS lift
FROM preceded p
JOIN hours h USING (comp)
LEFT JOIN errs e USING (comp, error_id)
ORDER BY p.comp, p.error_id;

CREATE VIEW v_failure_warning AS
SELECT f.machine_id,
       f.datetime,
       f.components,
       COUNT(e.error_id)                                                           AS errors_48h,
       STRING_AGG(DISTINCT e.error_id, ', ')                                       AS error_types_48h,
       ROUND(EXTRACT(EPOCH FROM f.datetime - MIN(e.datetime))::numeric / 3600, 0)  AS hours_first_error_before
FROM v_failure_events f
LEFT JOIN errors e
       ON e.machine_id = f.machine_id
      AND e.datetime >= f.datetime - INTERVAL '48 hours'
      AND e.datetime <  f.datetime
GROUP BY f.machine_id, f.datetime, f.components;
