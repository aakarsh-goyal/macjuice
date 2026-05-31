from __future__ import annotations


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
