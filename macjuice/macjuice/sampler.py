from __future__ import annotations

import plistlib
import re
import subprocess
import time


# ---------------------------------------------------------------------------
# parse_ioreg
# ---------------------------------------------------------------------------

def parse_ioreg(raw: bytes) -> dict:
    """Parse `ioreg -arn AppleSmartBattery` plist bytes into normalized fields.

    Returns {} on parse failure. Missing individual fields are None.
    Amperage and watts are signed (negative = discharging).
    """
    try:
        records = plistlib.loads(raw)
    except Exception:
        return {}
    if not records:
        return {}
    r = records[0] if isinstance(records, list) else records

    voltage_mv = r.get("Voltage")
    amperage_ma = r.get("Amperage")
    if amperage_ma is not None and amperage_ma > 2**31:
        amperage_ma -= 2**32
    temp = r.get("Temperature")

    voltage_v = voltage_mv / 1000 if voltage_mv is not None else None
    watts = (
        voltage_v * amperage_ma / 1000
        if voltage_v is not None and amperage_ma is not None
        else None
    )
    return {
        "cycle_count": r.get("CycleCount"),
        "design_mah": r.get("DesignCapacity"),
        "max_mah": r.get("AppleRawMaxCapacity"),
        "current_mah": r.get("AppleRawCurrentCapacity"),
        "temp_c": temp / 100 if temp is not None else None,
        "voltage_v": voltage_v,
        "amperage_ma": amperage_ma,
        "watts": watts,
        "charging": 1 if r.get("IsCharging") else 0,
        "serial": r.get("Serial"),
    }


# ---------------------------------------------------------------------------
# parse_pmset_batt
# ---------------------------------------------------------------------------

# Time may be "H:MM" or the literal "(no estimate)" — make it optional.
_BATT_LINE = re.compile(
    r"-InternalBattery.*?(\d+)%;\s*([a-zA-Z ]+?);\s*(?:(\d+):(\d+)|\(no estimate\))"
)


def parse_pmset_batt(text: str) -> dict:
    """Parse `pmset -g batt`. Internal battery only; UPS lines ignored."""
    m = _BATT_LINE.search(text)
    if not m:
        return {}
    pct = int(m.group(1))
    state = m.group(2).strip().lower()
    if m.group(3) is not None:
        total = int(m.group(3)) * 60 + int(m.group(4))
    else:
        total = 0
    time_remaining = total if total > 0 else None
    charging = 0 if state == "discharging" else 1
    return {
        "charge_pct": pct,
        "charging": charging,
        "time_remaining_min": time_remaining,
    }


# ---------------------------------------------------------------------------
# parse_system_profiler + parse_hardware
# ---------------------------------------------------------------------------

def parse_system_profiler(text: str) -> dict:
    """Parse `system_profiler SPPowerDataType` for the hourly heavy fields."""
    out = {
        "condition": None,
        "max_capacity_reported_pct": None,
        "cycle_count_reported": None,
    }
    m = re.search(r"Condition:\s*(.+)", text)
    if m:
        out["condition"] = m.group(1).strip()
    m = re.search(r"Maximum Capacity:\s*(\d+)%", text)
    if m:
        out["max_capacity_reported_pct"] = int(m.group(1))
    m = re.search(r"Cycle Count:\s*(\d+)", text)
    if m:
        out["cycle_count_reported"] = int(m.group(1))
    return out


def parse_hardware(text: str) -> str | None:
    """Parse `system_profiler SPHardwareDataType` for the Mac model name."""
    m = re.search(r"Model Name:\s*(.+)", text)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------------------
# subprocess helpers
# ---------------------------------------------------------------------------

_HEAVY_KEYS = ("condition", "max_capacity_reported_pct", "model", "heavy_ts")


def _run(cmd: list) -> bytes:
    return subprocess.run(cmd, capture_output=True, timeout=15).stdout


def read_light() -> dict:
    """Run ioreg + pmset and merge their parsed fields."""
    d = {}
    try:
        d.update(parse_ioreg(_run(["ioreg", "-arn", "AppleSmartBattery"])))
    except Exception:
        pass
    try:
        d.update(parse_pmset_batt(_run(["pmset", "-g", "batt"]).decode()))
    except Exception:
        pass
    return d


def read_heavy() -> dict:
    """Run system_profiler (power + hardware) for hourly fields."""
    out = {
        "heavy_ts": int(time.time()),
        "model": None,
        "condition": None,
        "max_capacity_reported_pct": None,
    }
    try:
        power = _run(["system_profiler", "SPPowerDataType"]).decode()
        sp = parse_system_profiler(power)
        out["condition"] = sp.get("condition")
        out["max_capacity_reported_pct"] = sp.get("max_capacity_reported_pct")
    except Exception:
        pass
    try:
        hw = _run(["system_profiler", "SPHardwareDataType"]).decode()
        out["model"] = parse_hardware(hw)
    except Exception:
        pass
    return out


def read(heavy_cache) -> dict:
    """One full live sample: fresh light read + cached heavy fields."""
    s = read_light()
    s["ts"] = int(time.time())
    s["source"] = "live"
    for k in _HEAVY_KEYS:
        s[k] = (heavy_cache or {}).get(k)
    return s
