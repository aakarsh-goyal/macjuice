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


def test_parse_system_profiler():
    text = (FIX / "system_profiler_power.txt").read_text()
    d = sampler.parse_system_profiler(text)
    assert d["condition"] == "Normal"
    assert 0 < d["max_capacity_reported_pct"] <= 200
    assert d["cycle_count_reported"] >= 0


def test_parse_hardware_model():
    text = (
        "Hardware:\n\n    Hardware Overview:\n\n"
        "      Model Name: MacBook Pro\n"
        "      Model Identifier: Mac15,3\n"
    )
    assert sampler.parse_hardware(text) == "MacBook Pro"


def test_read_merges_light_and_heavy(monkeypatch):
    monkeypatch.setattr(sampler, "read_light", lambda: {
        "charge_pct": 50, "charging": 0, "watts": -10.0, "cycle_count": 223,
    })
    heavy_cache = {
        "condition": "Normal", "max_capacity_reported_pct": 91,
        "model": "MacBook Pro", "heavy_ts": 1000,
    }
    s = sampler.read(heavy_cache)
    assert s["charge_pct"] == 50
    assert s["condition"] == "Normal"
    assert s["max_capacity_reported_pct"] == 91
    assert s["model"] == "MacBook Pro"
    assert s["heavy_ts"] == 1000
    assert s["source"] == "live"
    assert "ts" in s


def test_read_with_no_heavy_cache(monkeypatch):
    monkeypatch.setattr(sampler, "read_light", lambda: {"charge_pct": 42})
    s = sampler.read(None)
    assert s["charge_pct"] == 42
    assert s["condition"] is None
    assert s["max_capacity_reported_pct"] is None


def test_parse_pmset_batt_ac_attached_not_charging():
    # real macOS format when plugged in but holding charge — no time field at all
    text = (
        "Now drawing from 'AC Power'\n"
        " -InternalBattery-0 (id=22741091)\t80%; AC attached; not charging "
        "present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 80
    assert d["charging"] == 1            # on AC, not discharging
    assert d["time_remaining_min"] is None


def test_parse_pmset_batt_charging_with_time():
    text = (
        "Now drawing from 'AC Power'\n"
        " -InternalBattery-0 (id=1)\t45%; charging; 1:30 remaining present: true\n"
    )
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 45
    assert d["charging"] == 1
    assert d["time_remaining_min"] == 90


def test_parse_pmset_batt_finishing_charge():
    text = " -InternalBattery-0 (id=1)\t99%; finishing charge; 0:05 remaining present: true\n"
    d = sampler.parse_pmset_batt(text)
    assert d["charge_pct"] == 99
    assert d["charging"] == 1
    assert d["time_remaining_min"] == 5
