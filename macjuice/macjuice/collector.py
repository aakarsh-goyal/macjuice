from __future__ import annotations

import time

from . import sampler, store
from .paths import db_path

HEAVY_INTERVAL_S = 3600
DEFAULT_INTERVAL_S = 120


def diff_events(prev, cur) -> list:
    """Return [(type, ts, detail)] for transitions between two samples."""
    if prev is None:
        return []
    evs = []
    ts = cur["ts"]
    if prev.get("charging") == 0 and cur.get("charging") == 1:
        evs.append(("plug_in", ts, None))
    elif prev.get("charging") == 1 and cur.get("charging") == 0:
        evs.append(("unplug", ts, None))
    if prev.get("charge_pct", 0) < 100 and cur.get("charge_pct") == 100:
        evs.append(("full_charge", ts, None))
    return evs


def collect_once(conn, heavy_cache, prev) -> dict:
    sample = sampler.read(heavy_cache)
    store.insert_sample(conn, sample)
    for type_, ts, detail in diff_events(prev, sample):
        store.insert_event(conn, ts, type_, "live", detail)
    return sample


def run(interval_s: int = DEFAULT_INTERVAL_S) -> None:  # pragma: no cover
    conn = store.connect(db_path())
    store.init_db(conn)
    heavy_cache = sampler.read_heavy()
    prev = store.latest(conn)
    while True:
        now = time.time()
        if now - heavy_cache.get("heavy_ts", 0) >= HEAVY_INTERVAL_S:
            heavy_cache = sampler.read_heavy()
        try:
            prev = collect_once(conn, heavy_cache, prev)
        except Exception as exc:
            print(f"[macjuice] sample failed: {exc}", flush=True)
        time.sleep(interval_s)


if __name__ == "__main__":  # pragma: no cover
    run()
