import pathlib
from macjuice import sampler

FIX = pathlib.Path(__file__).parent / "fixtures"


def test_parse_ioreg_fields():
    raw = (FIX / "ioreg.xml").read_bytes()
    d = sampler.parse_ioreg(raw)
    assert isinstance(d["cycle_count"], int) and d["cycle_count"] >= 0
    assert d["design_mah"] > 0
    assert d["max_mah"] > 0
    assert 0 < d["temp_c"] < 80
    assert 5 < d["voltage_v"] < 30
    assert abs(d["watts"] - (d["voltage_v"] * d["amperage_ma"] / 1000)) < 1e-6
    assert d["charging"] in (0, 1)


def test_parse_ioreg_malformed_returns_empty():
    assert sampler.parse_ioreg(b"not a plist") == {}


def test_parse_pmset_batt_discharging():
    text = (
        "Now drawing from 'Battery Power'\n"
        " -InternalBattery-0 (id=22741091)\t5%; discharging; 0:22 "
        "remaining present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 5
    assert d["charging"] == 0
    assert d["time_remaining_min"] == 22


def test_parse_pmset_batt_charged_no_estimate():
    text = (
        "Now drawing from 'AC Power'\n"
        " -InternalBattery-0 (id=22741091)\t100%; charged; 0:00 "
        "remaining present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 100
    assert d["charging"] == 1
    assert d["time_remaining_min"] is None


def test_parse_pmset_batt_no_estimate_string():
    text = (
        "Now drawing from 'Battery Power'\n"
        " -InternalBattery-0 (id=1)\t72%; discharging; (no estimate) "
        "present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 72
    assert d["charging"] == 0
    assert d["time_remaining_min"] is None


def test_parse_pmset_batt_ignores_ups():
    text = (
        "Now drawing from 'AC Power'\n"
        " -InternalBattery-0 (id=1)\t80%; charging; 1:30 remaining present: true\n"
        " -UPS0 (id=2)\t55%; discharging; 0:40 remaining present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 80
