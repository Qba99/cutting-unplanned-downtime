-- 01_create_tables.sql
-- Tables for the predictive-maintenance project (PostgreSQL 13+).
-- src/load_db.py runs this file, then fills the tables from data/raw/*.csv with COPY.
-- Re-running it drops and rebuilds everything, so a load is always repeatable.
--
-- Column names: the Kaggle CSVs use camelCase (machineID, errorID); here they are
-- snake_case. "failure" in PdM_failures.csv is renamed comp, to match maint.

DROP TABLE IF EXISTS failures  CASCADE;   -- CASCADE also drops the views built on them
DROP TABLE IF EXISTS maint     CASCADE;
DROP TABLE IF EXISTS errors    CASCADE;
DROP TABLE IF EXISTS telemetry CASCADE;
DROP TABLE IF EXISTS machines  CASCADE;

-- One row per machine.
CREATE TABLE machines (
    machine_id  INTEGER   PRIMARY KEY,
    model       TEXT      NOT NULL CHECK (model IN ('model1', 'model2', 'model3', 'model4')),
    age         SMALLINT  NOT NULL CHECK (age BETWEEN 0 AND 50)      -- years
);

-- One row per machine per hour: the four sensor readings.
CREATE TABLE telemetry (
    datetime    TIMESTAMP         NOT NULL,
    machine_id  INTEGER           NOT NULL REFERENCES machines (machine_id),
    volt        DOUBLE PRECISION  NOT NULL,
    rotate      DOUBLE PRECISION  NOT NULL,
    pressure    DOUBLE PRECISION  NOT NULL,
    vibration   DOUBLE PRECISION  NOT NULL,
    PRIMARY KEY (machine_id, datetime)       -- also serves as the (machine, time) index
);

-- Non-breaking error codes. A machine can log several codes in the same hour.
CREATE TABLE errors (
    datetime    TIMESTAMP  NOT NULL,
    machine_id  INTEGER    NOT NULL REFERENCES machines (machine_id),
    error_id    TEXT       NOT NULL CHECK (error_id IN ('error1', 'error2', 'error3', 'error4', 'error5')),
    PRIMARY KEY (machine_id, datetime, error_id)
);

-- Component replacements, both scheduled and after a failure (June 2014 onwards).
CREATE TABLE maint (
    datetime    TIMESTAMP  NOT NULL,
    machine_id  INTEGER    NOT NULL REFERENCES machines (machine_id),
    comp        TEXT       NOT NULL CHECK (comp IN ('comp1', 'comp2', 'comp3', 'comp4')),
    PRIMARY KEY (machine_id, datetime, comp)
);

-- Component failures. Two components can fail in the same event (same machine and hour).
CREATE TABLE failures (
    datetime    TIMESTAMP  NOT NULL,
    machine_id  INTEGER    NOT NULL REFERENCES machines (machine_id),
    comp        TEXT       NOT NULL CHECK (comp IN ('comp1', 'comp2', 'comp3', 'comp4')),
    PRIMARY KEY (machine_id, datetime, comp)
);

-- Extra indexes for the time-window joins in the analysis (errors before failures etc.).
CREATE INDEX idx_errors_time   ON errors   (datetime);
CREATE INDEX idx_maint_time    ON maint    (datetime);
CREATE INDEX idx_failures_time ON failures (datetime);
