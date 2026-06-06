import json

from macjuice import app as appmod, store


def _client(tmp_path, monkeypatch):
    dbfile = tmp_path / "app.db"
    conn = store.connect(dbfile)
    store.init_db(conn)
    for i in range(5):
        store.insert_sample(conn, {**{c: None for c in store._COLS},
            "ts": 1000 + i * 120, "source": "live", "charge_pct": 100 - i,
            "max_mah": 3954, "design_mah": 4629, "watts": -10, "charging": 0})
    monkeypatch.setenv("MACJUICE_DB", str(dbfile))
    flask_app = appmod.create_app()
    flask_app.config["TESTING"] = True
    return flask_app.test_client()


def test_history_endpoint(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    resp = c.get("/api/history?range=all")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert len(data["points"]) >= 1
    assert "charge_pct" in data["points"][0]


def test_history_downsamples(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    resp = c.get("/api/history?range=all&bucket=100000")
    data = json.loads(resp.data)
    assert len(data["points"]) == 1


def test_analytics_endpoint(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    resp = c.get("/api/analytics")
    data = json.loads(resp.data)
    assert "health_capacity_pct" in data
    assert "estimated_full_runtime" in data


def test_live_endpoint(tmp_path, monkeypatch):
    from macjuice import sampler
    monkeypatch.setattr(sampler, "read_light", lambda: {"charge_pct": 77})
    c = _client(tmp_path, monkeypatch)
    resp = c.get("/api/live")
    data = json.loads(resp.data)
    assert data["charge_pct"] == 77
    assert "sampled_at" in data


def test_shutdown_dashboard(tmp_path, monkeypatch):
    called = []
    monkeypatch.setattr(appmod, "_stop_agent", lambda label: called.append(label))
    c = _client(tmp_path, monkeypatch)
    resp = c.post("/api/shutdown?target=dashboard")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert data["stopped"] == ["com.macjuice.dashboard"]
    assert called == ["com.macjuice.dashboard"]


def test_shutdown_all_stops_collector_then_dashboard(tmp_path, monkeypatch):
    called = []
    monkeypatch.setattr(appmod, "_stop_agent", lambda label: called.append(label))
    c = _client(tmp_path, monkeypatch)
    resp = c.post("/api/shutdown?target=all")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert called == ["com.macjuice.collector", "com.macjuice.dashboard"]
    assert data["stopped"] == ["com.macjuice.collector", "com.macjuice.dashboard"]


def test_shutdown_unknown_target(tmp_path, monkeypatch):
    called = []
    monkeypatch.setattr(appmod, "_stop_agent", lambda label: called.append(label))
    c = _client(tmp_path, monkeypatch)
    resp = c.post("/api/shutdown?target=bogus")
    assert resp.status_code == 400
    assert called == []


def test_uninstall_keeps_data_by_default(tmp_path, monkeypatch):
    removed, wiped = [], []
    monkeypatch.setattr(appmod, "_remove_agent", lambda label: removed.append(label))
    monkeypatch.setattr(appmod, "_wipe_data", lambda: wiped.append(True))
    c = _client(tmp_path, monkeypatch)
    resp = c.post("/api/uninstall")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert removed == ["com.macjuice.collector", "com.macjuice.dashboard"]
    assert data["data_wiped"] is False
    assert wiped == []


def test_uninstall_with_data_wipe(tmp_path, monkeypatch):
    removed, wiped = [], []
    monkeypatch.setattr(appmod, "_remove_agent", lambda label: removed.append(label))
    monkeypatch.setattr(appmod, "_wipe_data", lambda: wiped.append(True))
    c = _client(tmp_path, monkeypatch)
    resp = c.post("/api/uninstall?data=wipe")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert data["data_wiped"] is True
    assert wiped == [True]
    assert removed == ["com.macjuice.collector", "com.macjuice.dashboard"]


def test_selfcost_endpoint(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    # seed a couple self_metrics rows directly
    import os
    from macjuice import store as st
    conn = st.connect(os.environ["MACJUICE_DB"])
    st.insert_self_metric(conn, {"ts": 0, "collector_cpu_s": 10, "dashboard_cpu_s": 5,
                                 "collector_rss_mb": 20, "dashboard_rss_mb": 50})
    st.insert_self_metric(conn, {"ts": 7200, "collector_cpu_s": 12, "dashboard_cpu_s": 6,
                                 "collector_rss_mb": 22, "dashboard_rss_mb": 52})
    resp = c.get("/api/selfcost")
    data = json.loads(resp.data)
    assert resp.status_code == 200
    assert "cpu_s_per_day" in data and data["cpu_s_per_day"] > 0
    assert "pct_per_day" in data and "assumed_w" in data
