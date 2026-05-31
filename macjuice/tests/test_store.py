from macjuice import store


def _sample(ts, **over):
    base = dict(
        ts=ts, source="live", charge_pct=50, current_mah=2000, max_mah=3954,
        design_mah=4629, cycle_count=223, max_capacity_reported_pct=91,
        condition="Normal", heavy_ts=ts, temp_c=30.6, voltage_v=11.0,
        amperage_ma=-300, watts=-3.3, charging=0, adapter_watts=None,
        time_remaining_min=120, serial="ABC", model="MacBook Pro",
    )
    base.update(over)
    return base


def test_insert_and_latest(tmp_path):
    conn = store.connect(tmp_path / "t.db")
    store.init_db(conn)
    store.insert_sample(conn, _sample(1000))
    store.insert_sample(conn, _sample(1120, charge_pct=48))
    latest = store.latest(conn)
    assert latest["ts"] == 1120
    assert latest["charge_pct"] == 48


def test_insert_or_ignore_same_second(tmp_path):
    conn = store.connect(tmp_path / "t.db")
    store.init_db(conn)
    store.insert_sample(conn, _sample(1000, charge_pct=50))
    store.insert_sample(conn, _sample(1000, charge_pct=99))  # same ts
    rows = store.query_range(conn, 0, 9999)
    assert len(rows) == 1
    assert rows[0]["charge_pct"] == 50  # first one kept


def test_query_range_and_events(tmp_path):
    conn = store.connect(tmp_path / "t.db")
    store.init_db(conn)
    for ts in (1000, 1120, 1240):
        store.insert_sample(conn, _sample(ts))
    store.insert_event(conn, 1130, "unplug", "live", None)
    assert len(store.query_range(conn, 1100, 1200)) == 1
    evs = store.query_events(conn, 0, 9999)
    assert evs[0]["type"] == "unplug"


def test_wal_pragma(tmp_path):
    conn = store.connect(tmp_path / "t.db")
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert mode.lower() == "wal"


def test_meta_roundtrip(tmp_path):
    conn = store.connect(tmp_path / "t.db")
    store.init_db(conn)
    store.set_meta(conn, "model", "MacBook Pro")
    assert store.get_meta(conn, "model") == "MacBook Pro"
