"""Shared helpers for the predictive-maintenance notebooks.

Loading the raw Kaggle CSVs, building control limits, turning a rule into alerts and
scoring alerts against real failures all live here, so every notebook uses exactly the
same definitions (see docs/01_problem_statement.md).
"""
from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = REPO_ROOT / "data" / "raw"
EXPORT_DIR = REPO_ROOT / "data" / "exports"
IMAGE_DIR = REPO_ROOT / "images"

SENSORS = ["volt", "rotate", "pressure", "vibration"]
SENSOR_LABEL = {"volt": "Voltage", "rotate": "Rotation", "pressure": "Pressure", "vibration": "Vibration"}
COMPONENTS = ["comp1", "comp2", "comp3", "comp4"]

# Train/test split for the alert rules: rules and thresholds are chosen on TRAIN only.
TRAIN = (pd.Timestamp("2015-01-01"), pd.Timestamp("2015-09-01"))
TEST = (pd.Timestamp("2015-09-01"), pd.Timestamp("2016-01-02"))

# Colours (validated reference palette; see the README's chart notes)
INK, INK_2, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]     # categorical slots 1-4, fixed order
CRITICAL = "#d03b3b"                                         # out-of-control points, failures


# --------------------------------------------------------------------------- style
def set_style() -> None:
    """Quiet axes, hairline grid, readable type: the look of every chart in the repo."""
    plt.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "figure.dpi": 110, "savefig.dpi": 160, "savefig.bbox": "tight",
        "font.size": 10, "axes.titlesize": 12, "axes.titleweight": "bold",
        "axes.titlelocation": "left", "axes.titlepad": 10,
        "axes.labelcolor": INK_2, "axes.edgecolor": AXIS, "axes.linewidth": 0.8,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
        "axes.axisbelow": True, "text.color": INK,
        "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": INK_2, "ytick.labelcolor": INK_2,
        "legend.frameon": False, "lines.linewidth": 2,
    })


def save(fig, name: str) -> Path:
    IMAGE_DIR.mkdir(exist_ok=True)
    path = IMAGE_DIR / name
    fig.savefig(path)
    return path


# --------------------------------------------------------------------------- data
def load_raw() -> dict[str, pd.DataFrame]:
    """The five Kaggle tables with snake_case columns, sorted by machine and time."""
    rename = {"machineID": "machine_id", "errorID": "error_id", "failure": "comp"}
    out = {}
    for name in ["telemetry", "errors", "maint", "failures", "machines"]:
        df = pd.read_csv(RAW_DIR / f"PdM_{name}.csv").rename(columns=rename)
        if "datetime" in df:
            df["datetime"] = pd.to_datetime(df["datetime"])
            df = df.sort_values(["machine_id", "datetime"]).reset_index(drop=True)
        out[name] = df
    return out


def failure_events(failures: pd.DataFrame) -> pd.DataFrame:
    """One row per machine + hour (761 component failures -> 719 events)."""
    return (failures.groupby(["machine_id", "datetime"])["comp"]
            .agg(lambda s: ", ".join(sorted(s))).rename("components").reset_index())


def load_export(view: str) -> pd.DataFrame:
    """A CSV written by src/export_views.py."""
    return pd.read_csv(EXPORT_DIR / f"{view}.csv")


# --------------------------------------------------------------------------- control limits
def add_daily_mean(tel: pd.DataFrame, hours: int = 24) -> pd.DataFrame:
    """Rolling mean of each sensor over the last `hours` hours (column <sensor>_24h).

    Hourly readings are noisy; a failure shows as a shift lasting a day or more, which the
    daily mean makes visible. The first 23 hours of each machine have no value.
    """
    tel = tel.sort_values(["machine_id", "datetime"]).reset_index(drop=True)
    rolled = (tel.groupby("machine_id")[SENSORS]
              .rolling(hours, min_periods=hours).mean().reset_index(level=0, drop=True))
    for s in SENSORS:
        tel[f"{s}_24h"] = rolled[s]
    return tel


def baseline_limits(tel: pd.DataFrame, events: pd.DataFrame, days: int = 30,
                    exclude_before_days: int = 7, exclude_after_days: int = 2) -> pd.DataFrame:
    """Centre line and sigma per machine and sensor, from that machine's own normal running.

    Baseline = the first `days` days of data, minus the `exclude_before_days` before any
    failure and the `exclude_after_days` after it (the daily mean is still disturbed then).
    Returns one row per machine with <sensor>_mean and <sensor>_sd columns.
    """
    start = tel["datetime"].min()
    base = tel[(tel["datetime"] < start + pd.Timedelta(days=days)) & tel[f"{SENSORS[0]}_24h"].notna()]
    ev = events[events["datetime"] < start + pd.Timedelta(days=days + exclude_before_days)]
    keep = np.ones(len(base), dtype=bool)
    for r in ev.itertuples():
        keep &= ~((base["machine_id"].values == r.machine_id)
                  & (base["datetime"].values >= np.datetime64(r.datetime - pd.Timedelta(days=exclude_before_days)))
                  & (base["datetime"].values < np.datetime64(r.datetime + pd.Timedelta(days=exclude_after_days))))
    base = base[keep]
    agg = base.groupby("machine_id")[[f"{s}_24h" for s in SENSORS]].agg(["mean", "std", "count"])
    out = pd.DataFrame(index=agg.index)
    for s in SENSORS:
        out[f"{s}_mean"] = agg[(f"{s}_24h", "mean")]
        out[f"{s}_sd"] = agg[(f"{s}_24h", "std")]
    out["baseline_hours"] = agg[(f"{SENSORS[0]}_24h", "count")]
    return out.reset_index()


def add_z(tel: pd.DataFrame, limits: pd.DataFrame) -> pd.DataFrame:
    """Distance of each daily mean from its machine's centre line, in baseline sigmas (<sensor>_z)."""
    lim = tel[["machine_id"]].merge(limits, on="machine_id", how="left")
    for s in SENSORS:
        tel[f"{s}_z"] = (tel[f"{s}_24h"].values - lim[f"{s}_mean"].values) / lim[f"{s}_sd"].values
    return tel


def hours_since_replacement(tel: pd.DataFrame, maint: pd.DataFrame) -> np.ndarray:
    """Hours since the last component replacement on the machine (NaN if none yet)."""
    reps = maint[["machine_id", "datetime"]].drop_duplicates().rename(columns={"datetime": "rep"})
    left = tel[["machine_id", "datetime"]].reset_index()
    joined = pd.merge_asof(left.sort_values("datetime"), reps.sort_values("rep"),
                           left_on="datetime", right_on="rep", by="machine_id", direction="backward")
    joined = joined.sort_values("index")
    return ((joined["datetime"] - joined["rep"]).dt.total_seconds() / 3600).values


def recent_error(tel: pd.DataFrame, errors: pd.DataFrame, codes: list[str] | None = None,
                 hours: int = 24) -> np.ndarray:
    """True for each machine-hour with at least one of `codes` (all codes if None) in the last `hours`."""
    e = errors if codes is None else errors[errors["error_id"].isin(codes)]
    marks = e[["machine_id", "datetime"]].drop_duplicates().assign(hit=1)
    grid = tel[["machine_id", "datetime"]].merge(marks, how="left", on=["machine_id", "datetime"])
    grid["hit"] = grid["hit"].fillna(0)
    rolled = grid.groupby("machine_id")["hit"].transform(lambda s: s.rolling(hours, min_periods=1).sum())
    return (rolled > 0).values


# --------------------------------------------------------------------------- alerts
def alerts_from_flag(tel: pd.DataFrame, flag, min_hours: int = 1, merge_days: int = 7) -> pd.DataFrame:
    """Turn an hourly True/False condition into alerts.

    An alert fires in the hour the condition has held for `min_hours` hours in a row.
    Further firings on the same machine within `merge_days` of an alert belong to that alert
    (one technician visit, not seven).
    """
    df = tel[["machine_id", "datetime"]].copy()
    df["f"] = np.asarray(flag, dtype=bool)
    run_id = ((df["f"] != df["f"].shift()) | (df["machine_id"] != df["machine_id"].shift())).cumsum()
    df["run"] = df["f"].astype(int).groupby(run_id).cumsum()
    hits = df[df["f"] & (df["run"] >= min_hours)]
    out, gap = [], pd.Timedelta(days=merge_days)
    for mid, g in hits.groupby("machine_id"):
        last = None
        for ts in g["datetime"]:
            if last is None or ts - last > gap:
                out.append((mid, ts))
                last = ts
    return pd.DataFrame(out, columns=["machine_id", "datetime"])


def match_alerts(alerts: pd.DataFrame, events: pd.DataFrame, horizon_days: int = 7):
    """Pair alerts with the failures they warned about.

    An alert is TRUE when the same machine has a failure event 0-`horizon_days` days after it.
    A failure is CAUGHT when at least one alert came in the `horizon_days` before it; its lead
    time is measured from the EARLIEST such alert.
    Returns (alerts with is_true, events with caught and lead_hours).
    """
    j = alerts.reset_index().merge(events.reset_index(), on="machine_id", suffixes=("", "_f"))
    j = j[(j["datetime_f"] > j["datetime"]) & (j["datetime_f"] <= j["datetime"] + pd.Timedelta(days=horizon_days))]
    a = alerts.copy()
    a["is_true"] = a.index.isin(j["index"])
    first = j.groupby("index_f")["datetime"].min()
    e = events.copy()
    e["caught"] = e.index.isin(first.index)
    e["lead_hours"] = (e["datetime"] - e.index.map(first)).dt.total_seconds() / 3600
    return a, e


def score(alerts: pd.DataFrame, events: pd.DataFrame, period: tuple, horizon_days: int = 7) -> dict:
    """Recall, precision and lead time of a set of alerts within a period [start, end)."""
    lo, hi = period
    a = alerts[(alerts["datetime"] >= lo) & (alerts["datetime"] < hi)].reset_index(drop=True)
    e = events[(events["datetime"] >= lo) & (events["datetime"] < hi)].reset_index(drop=True)
    a, e = match_alerts(a, e, horizon_days)
    n_true = int(a["is_true"].sum())
    return {
        "failures": len(e),
        "caught": int(e["caught"].sum()),
        "missed": int((~e["caught"]).sum()),
        "alerts": len(a),
        "true_alerts": n_true,
        "false_alarms": len(a) - n_true,
        "recall": e["caught"].mean() if len(e) else np.nan,
        "precision": n_true / len(a) if len(a) else np.nan,
        "median_lead_hours": e.loc[e["caught"], "lead_hours"].median(),
    }
