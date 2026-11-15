-- 03_data_quality.sql
-- Data-quality checks, one row per check. src/load_db.py runs this after every load,
-- prints the results and writes them to docs/02_data_quality_log.md.
--
-- result = PASS / FAIL  a rule the data must meet before any analysis
--          INFO         a fact about the data that shapes the analysis (no pass mark)
--
-- Nulls and duplicate rows are blocked by the NOT NULL constraints and primary keys in
-- 01_create_tables.sql: if the load succeeds, there are none.
-- Run on its own in pgAdmin or psql:  SELECT * FROM v_data_quality;

DROP VIEW IF EXISTS v_data_quality;

CREATE VIEW v_data_quality AS

-- 1. Row counts match the Kaggle files --------------------------------------------
SELECT 'DQ01' AS check_id, 'Row counts' AS area, 'machines rows' AS check_name,
       '100' AS expected, COUNT(*)::text AS actual,
       CASE WHEN COUNT(*) = 100 THEN 'PASS' ELSE 'FAIL' END AS result
FROM machines
UNION ALL
SELECT 'DQ02', 'Row counts', 'telemetry rows', '876,100', TO_CHAR(COUNT(*), 'FM999,999,999'),
       CASE WHEN COUNT(*) = 876100 THEN 'PASS' ELSE 'FAIL' END
FROM telemetry
UNION ALL
SELECT 'DQ03', 'Row counts', 'errors rows', '3,919', TO_CHAR(COUNT(*), 'FM999,999,999'),
       CASE WHEN COUNT(*) = 3919 THEN 'PASS' ELSE 'FAIL' END
FROM errors
UNION ALL
SELECT 'DQ04', 'Row counts', 'maint rows', '3,286', TO_CHAR(COUNT(*), 'FM999,999,999'),
       CASE WHEN COUNT(*) = 3286 THEN 'PASS' ELSE 'FAIL' END
FROM maint
UNION ALL
SELECT 'DQ05', 'Row counts', 'failures rows', '761', COUNT(*)::text,
       CASE WHEN COUNT(*) = 761 THEN 'PASS' ELSE 'FAIL' END
FROM failures

-- 2. Telemetry is complete: every machine, every hour ------------------------------
UNION ALL
SELECT 'DQ06', 'Telemetry', 'machines with telemetry', '100', COUNT(DISTINCT machine_id)::text,
       CASE WHEN COUNT(DISTINCT machine_id) = 100 THEN 'PASS' ELSE 'FAIL' END
FROM telemetry
UNION ALL
SELECT 'DQ07', 'Telemetry', 'first and last reading',
       '2015-01-01 06:00 to 2016-01-01 06:00',
       TO_CHAR(MIN(datetime), 'YYYY-MM-DD HH24:MI') || ' to ' || TO_CHAR(MAX(datetime), 'YYYY-MM-DD HH24:MI'),
       CASE WHEN MIN(datetime) = '2015-01-01 06:00' AND MAX(datetime) = '2016-01-01 06:00'
            THEN 'PASS' ELSE 'FAIL' END
FROM telemetry
UNION ALL
SELECT 'DQ08', 'Telemetry', 'machines without exactly 8,761 hourly rows', '0', COUNT(*)::text,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT machine_id FROM telemetry GROUP BY machine_id HAVING COUNT(*) <> 8761) x
UNION ALL
SELECT 'DQ09', 'Telemetry', 'gaps: consecutive readings not 1 hour apart', '0', COUNT(*)::text,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT datetime - LAG(datetime) OVER (PARTITION BY machine_id ORDER BY datetime) AS step
      FROM telemetry) s
WHERE step <> INTERVAL '1 hour'
UNION ALL
SELECT 'DQ10', 'Telemetry', 'readings of zero or below (any sensor)', '0', COUNT(*)::text,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM telemetry
WHERE volt <= 0 OR rotate <= 0 OR pressure <= 0 OR vibration <= 0

-- 3. Sensor ranges and outliers (fleet mean +/- 3 standard deviations) -------------
-- Outliers are kept: unusual readings before a failure are exactly what we look for.
UNION ALL
SELECT 'DQ11', 'Sensors', 'range and outliers beyond fleet mean +/- 3 sd', 'kept, not removed',
       STRING_AGG(sensor || ' ' || lo || '-' || hi || ' (' || pct_out || '% out)', '; ' ORDER BY ord),
       'INFO'
FROM (
    SELECT ord, sensor,
           ROUND(MIN(v)::numeric, 1)::text AS lo,
           ROUND(MAX(v)::numeric, 1)::text AS hi,
           ROUND(100.0 * AVG(CASE WHEN ABS(v - mu) > 3 * sd THEN 1 ELSE 0 END), 2)::text AS pct_out
    FROM (
        SELECT ord, sensor, v,
               AVG(v)         OVER (PARTITION BY sensor) AS mu,
               STDDEV_POP(v)  OVER (PARTITION BY sensor) AS sd
        FROM telemetry t
        CROSS JOIN LATERAL (VALUES (1, 'volt', t.volt), (2, 'rotate', t.rotate),
                                   (3, 'pressure', t.pressure), (4, 'vibration', t.vibration)
                           ) AS u(ord, sensor, v)
    ) z
    GROUP BY ord, sensor
) s

-- 4. Events sit inside the analysis period and on the hour -------------------------
UNION ALL
SELECT 'DQ12', 'Timing', 'errors and failures outside the telemetry period', '0', COUNT(*)::text,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT datetime FROM errors UNION ALL SELECT datetime FROM failures) e
WHERE e.datetime < (SELECT MIN(datetime) FROM telemetry)
   OR e.datetime > (SELECT MAX(datetime) FROM telemetry)
UNION ALL
SELECT 'DQ13', 'Timing', 'timestamps not on the full hour (all tables)', '0', SUM(n)::text,
       CASE WHEN SUM(n) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT COUNT(*) AS n FROM telemetry WHERE datetime <> DATE_TRUNC('hour', datetime)
      UNION ALL SELECT COUNT(*) FROM errors   WHERE datetime <> DATE_TRUNC('hour', datetime)
      UNION ALL SELECT COUNT(*) FROM maint    WHERE datetime <> DATE_TRUNC('hour', datetime)
      UNION ALL SELECT COUNT(*) FROM failures WHERE datetime <> DATE_TRUNC('hour', datetime)) x
UNION ALL
SELECT 'DQ14', 'Timing', 'hour of day failures are logged', 'n/a',
       STRING_AGG(TO_CHAR(h, 'FM00') || ':00 ' || n, '; ' ORDER BY n DESC),
       'INFO'
FROM (SELECT EXTRACT(HOUR FROM datetime)::int AS h, COUNT(*) AS n FROM failures GROUP BY 1) x
UNION ALL
SELECT 'DQ15', 'Timing', 'maint rows outside calendar 2015', 'n/a',
       (SELECT COUNT(*) FROM maint WHERE datetime <  '2015-01-01')::text || ' before (from '
       || (SELECT TO_CHAR(MIN(datetime), 'YYYY-MM-DD') FROM maint) || '); '
       || (SELECT COUNT(*) FROM maint WHERE datetime >= '2016-01-01')::text || ' after',
       'INFO'

-- 5. How failures and replacements relate ------------------------------------------
UNION ALL
SELECT 'DQ16', 'Failures', 'failure events (machine + hour)', 'n/a',
       COUNT(*)::text || ' events from ' || SUM(n_components)::text || ' component failures; '
       || COUNT(*) FILTER (WHERE n_components > 1)::text || ' events with 2+ components',
       'INFO'
FROM v_failure_events
UNION ALL
SELECT 'DQ17', 'Failures', 'failures with a same-day replacement in maint', 'n/a',
       COUNT(*) FILTER (WHERE has_match)::text || ' of ' || COUNT(*)::text
       || COALESCE('; unmatched all at ' || STRING_AGG(DISTINCT TO_CHAR(datetime, 'YYYY-MM-DD HH24:MI'), ', ')
                   FILTER (WHERE NOT has_match), ''),
       'INFO'
FROM (SELECT f.datetime,
             EXISTS (SELECT 1 FROM maint m
                     WHERE m.machine_id = f.machine_id AND m.comp = f.comp
                       AND m.datetime::date = f.datetime::date) AS has_match
      FROM failures f) x
UNION ALL
SELECT 'DQ18', 'Failures', '2015 replacements by type', 'n/a',
       COUNT(*) FILTER (WHERE maint_type = 'scheduled')::text || ' scheduled; '
       || COUNT(*) FILTER (WHERE maint_type = 'after_failure')::text || ' after a failure',
       'INFO'
FROM v_maint_typed
WHERE in_2015
UNION ALL
SELECT 'DQ19', 'Failures', 'machines with no failure in 2015', 'n/a',
       COUNT(*)::text || COALESCE(' (machine ' || STRING_AGG(machine_id::text, ', ' ORDER BY machine_id) || ')', ''),
       'INFO'
FROM machines m
WHERE NOT EXISTS (SELECT 1 FROM failures f WHERE f.machine_id = m.machine_id)

-- 6. The fleet -----------------------------------------------------------------------
UNION ALL
SELECT 'DQ20', 'Machines', 'machines by model', 'n/a',
       STRING_AGG(model || ' ' || n, '; ' ORDER BY model), 'INFO'
FROM (SELECT model, COUNT(*) AS n FROM machines GROUP BY model) x
UNION ALL
SELECT 'DQ21', 'Machines', 'machines by age group', 'n/a',
       STRING_AGG(age_group || ' yrs ' || n, '; ' ORDER BY age_group_order), 'INFO'
FROM (SELECT age_group, age_group_order, COUNT(*) AS n
      FROM v_machines GROUP BY age_group, age_group_order) x;
