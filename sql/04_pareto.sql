-- 04_pareto.sql
-- Q1: Where do failures concentrate?
--
-- v_pareto_component     component failures by component, with cumulative %
-- v_pareto_model         failure events by machine model, per machine and cumulative %
-- v_pareto_age_group     failure events by age group, per machine and cumulative %
-- v_failures_per_machine one row per machine: failure events and failures per component
-- v_model_age_crosstab   model x age group: does age explain the gap between models?
--
-- Counting rules (docs/01_problem_statement.md):
--   components are counted as COMPONENT failures (761), because each one is a part to replace;
--   models, age groups and machines are counted as failure EVENTS (719), because each
--   event is one stoppage of a machine.
-- Every machine is observed for the full year, so "per machine" = per machine-year.

DROP VIEW IF EXISTS v_model_age_crosstab   CASCADE;
DROP VIEW IF EXISTS v_failures_per_machine CASCADE;
DROP VIEW IF EXISTS v_pareto_age_group     CASCADE;
DROP VIEW IF EXISTS v_pareto_model         CASCADE;
DROP VIEW IF EXISTS v_pareto_component     CASCADE;

CREATE VIEW v_pareto_component AS
WITH counts AS (
    SELECT comp, COUNT(*) AS failures
    FROM failures
    GROUP BY comp
)
SELECT comp,
       failures,
       ROUND(100.0 * failures / SUM(failures) OVER (), 1)                          AS pct_of_failures,
       ROUND(100.0 * SUM(failures) OVER (ORDER BY failures DESC, comp)
                   / SUM(failures) OVER (), 1)                                      AS cum_pct,
       RANK() OVER (ORDER BY failures DESC)                                         AS pareto_rank
FROM counts
ORDER BY failures DESC;

-- One row per machine; machines with no failure appear with zeros.
CREATE VIEW v_failures_per_machine AS
SELECT m.machine_id,
       m.model,
       m.age,
       m.age_group,
       m.age_group_order,
       COALESCE(e.failure_events, 0)                                   AS failure_events,
       COALESCE(c.component_failures, 0)                               AS component_failures,
       COALESCE(c.comp1, 0) AS comp1, COALESCE(c.comp2, 0) AS comp2,
       COALESCE(c.comp3, 0) AS comp3, COALESCE(c.comp4, 0) AS comp4
FROM v_machines m
LEFT JOIN (SELECT machine_id, COUNT(*) AS failure_events
           FROM v_failure_events GROUP BY machine_id) e USING (machine_id)
LEFT JOIN (SELECT machine_id,
                  COUNT(*)                                   AS component_failures,
                  COUNT(*) FILTER (WHERE comp = 'comp1')     AS comp1,
                  COUNT(*) FILTER (WHERE comp = 'comp2')     AS comp2,
                  COUNT(*) FILTER (WHERE comp = 'comp3')     AS comp3,
                  COUNT(*) FILTER (WHERE comp = 'comp4')     AS comp4
           FROM failures GROUP BY machine_id) c USING (machine_id);

CREATE VIEW v_pareto_model AS
WITH g AS (
    SELECT model,
           COUNT(*)                     AS machines,
           SUM(failure_events)          AS failure_events,
           SUM(component_failures)      AS component_failures,
           ROUND(AVG(age), 1)           AS avg_age
    FROM v_failures_per_machine
    GROUP BY model
)
SELECT model,
       machines,
       avg_age,
       failure_events,
       component_failures,
       ROUND(failure_events::numeric / machines, 2)                                 AS events_per_machine,
       ROUND(100.0 * failure_events / SUM(failure_events) OVER (), 1)               AS pct_of_events,
       ROUND(100.0 * SUM(failure_events) OVER (ORDER BY failure_events DESC, model)
                   / SUM(failure_events) OVER (), 1)                                AS cum_pct,
       ROUND(100.0 * machines / SUM(machines) OVER (), 1)                           AS pct_of_fleet
FROM g
ORDER BY failure_events DESC;

CREATE VIEW v_pareto_age_group AS
WITH g AS (
    SELECT age_group,
           age_group_order,
           COUNT(*)                     AS machines,
           SUM(failure_events)          AS failure_events,
           SUM(component_failures)      AS component_failures
    FROM v_failures_per_machine
    GROUP BY age_group, age_group_order
)
SELECT age_group,
       age_group_order,
       machines,
       failure_events,
       component_failures,
       ROUND(failure_events::numeric / machines, 2)                                 AS events_per_machine,
       ROUND(100.0 * failure_events / SUM(failure_events) OVER (), 1)               AS pct_of_events,
       ROUND(100.0 * SUM(failure_events) OVER (ORDER BY failure_events DESC, age_group_order)
                   / SUM(failure_events) OVER (), 1)                                AS cum_pct,
       ROUND(100.0 * machines / SUM(machines) OVER (), 1)                           AS pct_of_fleet
FROM g
ORDER BY failure_events DESC;

-- If model1 machines are simply older, the model gap would shrink inside each age group.
CREATE VIEW v_model_age_crosstab AS
SELECT model,
       age_group,
       age_group_order,
       COUNT(*)                                            AS machines,
       SUM(failure_events)                                 AS failure_events,
       ROUND(AVG(failure_events), 2)                       AS events_per_machine
FROM v_failures_per_machine
GROUP BY model, age_group, age_group_order
ORDER BY model, age_group_order;
