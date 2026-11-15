-- 02_clean_views.sql
-- Clean, analysis-ready views on top of the raw tables. Every later SQL file and the
-- notebooks read from these, so each definition below is made once, here.
--
-- v_machines        one row per machine, with its age group
-- v_failure_events  one row per failure EVENT (machine + timestamp); 761 component
--                   failures form 719 events, because 42 events replaced two components
-- v_maint_typed     every replacement, labelled after_failure or scheduled, plus the
--                   days since the previous replacement of the same component
--
-- Analysis year: calendar 2015 (telemetry runs 2015-01-01 06:00 to 2016-01-01 06:00).
-- maint starts in June 2014; those rows are kept for "days since previous replacement"
-- but are flagged in_2015 = FALSE so they stay out of 2015 counts and costs.

DROP VIEW IF EXISTS v_maint_typed    CASCADE;
DROP VIEW IF EXISTS v_failure_events CASCADE;
DROP VIEW IF EXISTS v_machines       CASCADE;

CREATE VIEW v_machines AS
SELECT machine_id,
       model,
       age,
       CASE WHEN age <= 5  THEN '0-5'
            WHEN age <= 10 THEN '6-10'
            WHEN age <= 15 THEN '11-15'
            ELSE                '16-20'
       END AS age_group,
       CASE WHEN age <= 5  THEN 1
            WHEN age <= 10 THEN 2
            WHEN age <= 15 THEN 3
            ELSE                4
       END AS age_group_order          -- for sorting in charts and Excel
FROM machines;

CREATE VIEW v_failure_events AS
SELECT f.machine_id,
       f.datetime,
       COUNT(*)                                  AS n_components,
       STRING_AGG(f.comp, ', ' ORDER BY f.comp)  AS components,
       -- did the plant log a replacement for every failed component that day?
       BOOL_AND(EXISTS (
           SELECT 1 FROM maint m
           WHERE m.machine_id = f.machine_id
             AND m.comp       = f.comp
             AND m.datetime::date = f.datetime::date
       ))                                        AS has_maint_record
FROM failures f
GROUP BY f.machine_id, f.datetime;

CREATE VIEW v_maint_typed AS
SELECT m.machine_id,
       m.datetime,
       m.comp,
       -- a replacement on the same machine, component and DAY as a failure is the repair
       -- after that failure; all other replacements are scheduled (preventive).
       -- Matching on the day, not the hour, keeps the rule robust to logging times.
       CASE WHEN EXISTS (
                SELECT 1 FROM failures f
                WHERE f.machine_id = m.machine_id
                  AND f.comp       = m.comp
                  AND f.datetime::date = m.datetime::date)
            THEN 'after_failure'
            ELSE 'scheduled'
       END AS maint_type,
       (m.datetime >= '2015-01-01' AND m.datetime < '2016-01-01') AS in_2015,
       -- days since this component was last replaced on this machine (NULL for the first)
       EXTRACT(EPOCH FROM m.datetime - LAG(m.datetime) OVER (
           PARTITION BY m.machine_id, m.comp ORDER BY m.datetime)) / 86400.0
           AS days_since_prev_replacement
FROM maint m;
