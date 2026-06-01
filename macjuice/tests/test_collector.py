from macjuice import collector, store


def test_diff_events_plug_transitions():
    prev = {"charging": 0, "charge_pct": 90}
    cur = {"ts": 200, "charging": 1, "charge_pct": 91}
    evs = collector.diff_events(prev, cur)
    assert ("plug_in", 200) in [(e[0], e[1]) for e in evs]


def test_diff_events_full_charge():
    prev = {"charging": 1, "charge_pct": 99}
    cur = {"ts": 300, "charging": 1, "charge_pct": 100}
    evs = collector.diff_events(prev, cur)
    assert any(e[0] == "full_charge" for e in evs)


def test_diff_events_none_prev():
    assert collector.diff_events(None, {"ts": 1, "charging": 0}) == []


def test_collect_once_writes_row(tmp_path, monkeypatch):
    from macjuice import sampler
    monkeypatch.setattr(sampler, "read_light", lambda: {
        "charge_pct": 80, "charging": 0, "watts": -5.0,
    })
    conn = store.connect(tmp_path / "c.db")
    store.init_db(conn)
    state = collector.collect_once(conn, heavy_cache=None, prev=None)
    rows = store.query_range(conn, 0, 2**31)
    assert len(rows) == 1
    assert rows[0]["charge_pct"] == 80
    assert state["charge_pct"] == 80
