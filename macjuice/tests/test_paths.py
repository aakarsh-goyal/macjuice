import os
from macjuice import paths


def test_env_override(tmp_path, monkeypatch):
    target = tmp_path / "sub" / "custom.db"
    monkeypatch.setenv("MACJUICE_DB", str(target))
    p = paths.db_path()
    assert p == target
    assert p.parent.is_dir()  # parent created


def test_default_location(monkeypatch):
    monkeypatch.delenv("MACJUICE_DB", raising=False)
    p = paths.db_path()
    assert p.name == "battery.db"
    assert "macjuice" in str(p)
