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
