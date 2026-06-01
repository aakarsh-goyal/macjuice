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


def test_runtime_since_full_charge():
    rows = [_row(1000, 100, -5), _row(4600, 80, -5)]
    events = [{"ts": 1000, "type": "full_charge"}]
    out = analytics.runtime_since_full_charge(rows, events)
    assert out["elapsed_min"] == 60
    assert out["pct_used"] == 20


def test_sessions_basic_discharge():
    rows = [
        {"ts": 0, "charge_pct": 100, "charging": 1, "watts": 0},
        {"ts": 100, "charge_pct": 100, "charging": 0, "watts": -10},
        {"ts": 250, "charge_pct": 95, "charging": 0, "watts": -10},
        {"ts": 400, "charge_pct": 90, "charging": 1, "watts": 5},
    ]
    s = analytics.sessions(rows, min_duration_s=60)
    assert len(s) == 1
    assert s[0]["pct_used"] == 10
    assert s[0]["duration_min"] == 5


def test_sessions_ignores_short_blip():
    rows = [
        {"ts": 0, "charge_pct": 100, "charging": 1, "watts": 0},
        {"ts": 10, "charge_pct": 100, "charging": 0, "watts": -10},
        {"ts": 20, "charge_pct": 100, "charging": 1, "watts": 5},
    ]
    assert analytics.sessions(rows, min_duration_s=60) == []


def test_charge_rate_pct_per_hour():
    rows = [_row(0, 80, 5), _row(3600, 90, 5)]  # +10% over 1h
    r = analytics.charge_rate(rows)
    assert round(r["pct_per_hour"], 1) == 10.0


def test_charge_rate_none_when_discharging():
    rows = [_row(0, 90, -5), _row(3600, 80, -5)]  # going down
    r = analytics.charge_rate(rows)
    assert r["pct_per_hour"] is None
