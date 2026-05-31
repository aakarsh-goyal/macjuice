from macjuice import analytics


def test_health_capacity_pct_uncapped():
    row = {"max_mah": 4800, "design_mah": 4629, "max_capacity_reported_pct": 100}
    h = analytics.health(row)
    assert round(h["health_capacity_pct"], 1) == round(4800 / 4629 * 100, 1)
    assert h["health_capacity_pct"] > 100
    assert h["health_reported_pct"] == 100


def test_health_missing_data():
    h = analytics.health({"max_mah": None, "design_mah": None})
    assert h["health_capacity_pct"] is None


def _row(ts, pct, watts):
    return {"ts": ts, "charge_pct": pct, "watts": watts}


def test_discharge_rate_pct_per_hour():
    rows = [_row(0, 100, -10), _row(3600, 90, -10)]
    r = analytics.discharge_rate(rows)
    assert round(r["pct_per_hour"], 1) == 10.0
    assert round(r["avg_watts"], 1) == 10.0


def test_estimate_insufficient_samples():
    rows = [_row(0, 100, -10), _row(120, 99, -10)]
    est = analytics.estimated_full_runtime(rows, min_samples=5)
    assert est["short_term_min"] is None


def test_estimate_with_enough_samples():
    rows = [_row(i * 120, 100 - i, -12) for i in range(10)]
    est = analytics.estimated_full_runtime(rows, min_samples=5)
    assert est["short_term_min"] is not None
    assert est["short_term_min"] > 0


def test_rate_rejects_clock_jump():
    rows = [_row(0, 100, -10), _row(-500, 90, -10)]
    r = analytics.discharge_rate(rows)
    assert r["pct_per_hour"] is None
