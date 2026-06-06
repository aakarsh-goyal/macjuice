from __future__ import annotations

# Stated assumption for the no-sudo energy estimate: effective SoC power drawn
# *while macjuice's CPU work is actually running*. Per-process power needs
# sudo/powermetrics, which macjuice avoids; this is a deliberately conservative
# proxy (real figure is likely lower). CPU-seconds themselves are measured exactly.
SELF_ACTIVE_WATTS = 2.0


def _sum_positive_deltas(rows, key):
    """Sum increases of a cumulative counter, skipping resets (process restarts)."""
    total, prev = 0.0, None
    for r in rows:
        v = r.get(key)
        if v is None:
            prev = None
            continue
        if prev is not None and v >= prev:
            total += v - prev
        prev = v
    return total


def self_cost(rows, battery_wh: float = 50.0,
              assumed_w: float = SELF_ACTIVE_WATTS) -> dict:
    """Estimate macjuice's own daily battery cost from logged self-metrics.

    CPU-seconds are exact (summed over the window, reset-safe). Energy and
    %-of-battery are derived using `assumed_w` and the battery's watt-hours.
    """
    empty = {
        "measured_hours": 0.0, "cpu_s_per_day": None,
        "collector_cpu_s_per_day": None, "dashboard_cpu_s_per_day": None,
        "energy_wh_per_day": None, "pct_per_day": None,
        "collector_rss_mb": None, "dashboard_rss_mb": None,
        "assumed_w": assumed_w, "battery_wh": battery_wh,
    }
    valid = [r for r in rows if r.get("ts") is not None]
    if len(valid) < 2:
        return empty
    span = valid[-1]["ts"] - valid[0]["ts"]
    if span <= 0:
        return empty

    per_day = 86400 / span
    col = _sum_positive_deltas(valid, "collector_cpu_s")
    dash = _sum_positive_deltas(valid, "dashboard_cpu_s")
    cpu_day = (col + dash) * per_day
    energy_day = cpu_day * assumed_w / 3600  # Wh
    last = valid[-1]
    return {
        "measured_hours": span / 3600,
        "cpu_s_per_day": cpu_day,
        "collector_cpu_s_per_day": col * per_day,
        "dashboard_cpu_s_per_day": dash * per_day,
        "energy_wh_per_day": energy_day,
        "pct_per_day": (energy_day / battery_wh * 100) if battery_wh else None,
        "collector_rss_mb": last.get("collector_rss_mb"),
        "dashboard_rss_mb": last.get("dashboard_rss_mb"),
        "assumed_w": assumed_w,
        "battery_wh": battery_wh,
    }


def health(row: dict) -> dict:
    """Two distinct health numbers; mAh ratio is uncapped (>100% allowed)."""
    mx, dz = row.get("max_mah"), row.get("design_mah")
    cap = (mx / dz * 100) if mx and dz else None
    return {
        "health_capacity_pct": cap,
        "health_reported_pct": row.get("max_capacity_reported_pct"),
    }


def _span(rows):
    """First/last by ts with a sane positive delta, else None."""
    if len(rows) < 2:
        return None
    first, last = rows[0], rows[-1]
    dt = last["ts"] - first["ts"]
    if dt <= 0 or dt > 7 * 24 * 3600:
        return None
    return first, last, dt


def discharge_rate(rows: list) -> dict:
    span = _span(rows)
    if not span:
        return {"pct_per_hour": None, "avg_watts": None}
    first, last, dt = span
    dpct = first["charge_pct"] - last["charge_pct"]
    watts = [abs(r["watts"]) for r in rows if r.get("watts") is not None]
    return {
        "pct_per_hour": dpct / (dt / 3600) if dpct >= 0 else None,
        "avg_watts": sum(watts) / len(watts) if watts else None,
    }


def charge_rate(rows: list) -> dict:
    span = _span(rows)
    if not span:
        return {"pct_per_hour": None}
    first, last, dt = span
    dpct = last["charge_pct"] - first["charge_pct"]
    return {"pct_per_hour": dpct / (dt / 3600) if dpct >= 0 else None}


def _runtime_from_window(rows, window_s, min_samples):
    if not rows:
        return None
    cutoff = rows[-1]["ts"] - window_s
    window = [r for r in rows if r["ts"] >= cutoff]
    if len(window) < min_samples:
        return None
    rate = discharge_rate(window)["pct_per_hour"]
    if not rate or rate <= 0:
        return None
    return 100 / rate * 60


def estimated_full_runtime(rows: list, min_samples: int = 5) -> dict:
    return {
        "short_term_min": _runtime_from_window(rows, 30 * 60, min_samples),
        "medium_term_min": _runtime_from_window(rows, 4 * 3600, min_samples),
    }


def runtime_since_full_charge(rows, events) -> dict:
    fulls = [e for e in events if e.get("type") == "full_charge"]
    if not fulls or not rows:
        return {"elapsed_min": None, "pct_used": None}
    full_ts = fulls[-1]["ts"]
    after = [r for r in rows if r["ts"] >= full_ts]
    if len(after) < 2:
        return {"elapsed_min": None, "pct_used": None}
    dt = after[-1]["ts"] - after[0]["ts"]
    if dt <= 0:
        return {"elapsed_min": None, "pct_used": None}
    return {
        "elapsed_min": dt / 60,
        "pct_used": after[0]["charge_pct"] - after[-1]["charge_pct"],
    }


def sessions(rows, min_duration_s: int = 120) -> list:
    """Discharge sessions: charging->discharging start, ->charging end."""
    out = []
    start = None
    prev = None
    for r in rows:
        if prev is not None:
            was, now = prev["charging"], r["charging"]
            if was == 1 and now == 0:
                start = r
            elif was == 0 and now == 1 and start is not None:
                out.append(_make_session(start, r))
                start = None
        prev = r
    if start is not None and prev is not None and prev is not start:
        out.append(_make_session(start, prev))
    return [s for s in out if s["duration_s"] >= min_duration_s]


def _make_session(start, end) -> dict:
    dt = max(end["ts"] - start["ts"], 0)
    return {
        "start_ts": start["ts"],
        "end_ts": end["ts"],
        "duration_s": dt,
        "duration_min": dt / 60,
        "pct_used": start["charge_pct"] - end["charge_pct"],
    }
