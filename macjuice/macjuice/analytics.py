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
