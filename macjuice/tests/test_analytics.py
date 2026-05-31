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
