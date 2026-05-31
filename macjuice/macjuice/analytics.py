from __future__ import annotations


def health(row: dict) -> dict:
    """Two distinct health numbers; mAh ratio is uncapped (>100% allowed)."""
    mx, dz = row.get("max_mah"), row.get("design_mah")
    cap = (mx / dz * 100) if mx and dz else None
    return {
        "health_capacity_pct": cap,
        "health_reported_pct": row.get("max_capacity_reported_pct"),
    }
