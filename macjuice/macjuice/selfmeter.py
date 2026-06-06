"""Measure macjuice's own resource cost without sudo.

Reads `ps` for the two long-lived macjuice processes (collector + dashboard)
and reports their cumulative CPU time and resident memory. CPU time is exact;
the energy estimate built on top of it (see analytics.self_cost) is a stated
approximation, since per-process power needs sudo/powermetrics which macjuice
deliberately avoids.
"""
from __future__ import annotations

import subprocess


def parse_cputime(s: str):
    """Parse a `ps` TIME field ("[DD-]HH:MM:SS.ss" / "MM:SS.ss") to seconds."""
    s = (s or "").strip()
    if not s:
        return None
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    try:
        parts = [float(p) for p in s.split(":")]
    except ValueError:
        return None
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, sec = parts[-3], parts[-2], parts[-1]
    return days * 86400 + h * 3600 + m * 60 + sec


def parse_ps(text: str) -> dict:
    """Parse `ps -Ao pid,time,rss,args` output for the two macjuice processes.

    Matches the module names in the command line, so paths that merely contain
    'macjuice' are ignored. RSS (KB) is converted to MB.
    """
    out = {
        "collector_cpu_s": None, "dashboard_cpu_s": None,
        "collector_rss_mb": None, "dashboard_rss_mb": None,
    }
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit():
            continue  # header / malformed
        _pid, cputime, rss, args = parts
        try:
            rss_mb = float(rss) / 1024
        except ValueError:
            rss_mb = None
        if "macjuice.collector" in args:
            out["collector_cpu_s"] = parse_cputime(cputime)
            out["collector_rss_mb"] = rss_mb
        elif "macjuice.app" in args:
            out["dashboard_cpu_s"] = parse_cputime(cputime)
            out["dashboard_rss_mb"] = rss_mb
    return out


def read() -> dict:
    """Live snapshot of macjuice's own CPU time + memory (empty dict on failure)."""
    try:
        txt = subprocess.run(
            ["ps", "-Ao", "pid,time,rss,args"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return parse_ps(txt)
    except Exception:
        return {}
