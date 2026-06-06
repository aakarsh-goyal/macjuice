from __future__ import annotations

import os
import subprocess
import time

from flask import Flask, jsonify, render_template, request

from . import analytics, sampler, store
from .paths import db_path

_RANGES = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "all": None}

COLLECTOR_LABEL = "com.macjuice.collector"
DASHBOARD_LABEL = "com.macjuice.dashboard"


def _conn():
    conn = store.connect(db_path())
    store.init_db(conn)
    return conn


def _stop_agent(label: str) -> None:
    """Unload a macjuice launchd agent so it stays stopped (no KeepAlive respawn).

    Runs detached after a 1s delay so the HTTP response returns before launchd
    tears down this process (relevant when stopping the dashboard itself).
    """
    plist = os.path.expanduser(f"~/Library/LaunchAgents/{label}.plist")
    subprocess.Popen(
        ["/bin/sh", "-c", f"sleep 1; launchctl unload '{plist}'"]
    )


def _bucket_for(range_key: str) -> int:
    return {"24h": 120, "7d": 900, "30d": 3600, "all": 3600}.get(range_key, 3600)


def create_app() -> Flask:
    app = Flask(__name__)

    @app.route("/")
    def index():
        return render_template("dashboard.html")

    @app.route("/api/live")
    def live():
        conn = _conn()
        last = store.latest(conn) or {}
        heavy = {k: last.get(k) for k in
                 ("condition", "max_capacity_reported_pct", "model", "heavy_ts")}
        s = sampler.read(heavy)
        s["sampled_at"] = int(time.time())
        return jsonify(s)

    @app.route("/api/history")
    def history():
        range_key = request.args.get("range", "24h")
        span = _RANGES.get(range_key, 86400)
        bucket = int(request.args.get("bucket", _bucket_for(range_key)))
        conn = _conn()
        now = int(time.time())
        start = 0 if span is None else now - span
        cur = conn.execute(
            """
            SELECT (ts / ?) AS b,
                   MAX(ts) AS ts,
                   AVG(charge_pct) AS charge_pct,
                   AVG(watts) AS watts,
                   AVG(temp_c) AS temp_c,
                   AVG(max_mah) AS max_mah,
                   AVG(design_mah) AS design_mah,
                   MAX(source) AS source
            FROM samples WHERE ts >= ?
            GROUP BY b ORDER BY ts
            """,
            (bucket, start),
        )
        points = [dict(r) for r in cur.fetchall()]
        return jsonify({"range": range_key, "bucket": bucket, "points": points})

    @app.route("/api/events")
    def events():
        conn = _conn()
        return jsonify(store.query_events(conn, 0, 2**31))

    @app.route("/api/sessions")
    def sessions():
        conn = _conn()
        rows = store.query_range(conn, 0, 2**31)
        return jsonify(analytics.sessions(rows))

    @app.route("/api/analytics")
    def analytics_route():
        conn = _conn()
        rows = store.query_range(conn, 0, 2**31)
        evs = store.query_events(conn, 0, 2**31)
        latest = store.latest(conn) or {}
        out = analytics.health(latest)
        out["discharge_rate"] = analytics.discharge_rate(rows)
        out["estimated_full_runtime"] = analytics.estimated_full_runtime(rows)
        out["runtime_since_full_charge"] = analytics.runtime_since_full_charge(
            rows, evs
        )
        return jsonify(out)

    @app.route("/api/shutdown", methods=["POST"])
    def shutdown():
        target = request.args.get("target", "dashboard")
        if target == "dashboard":
            labels = [DASHBOARD_LABEL]
        elif target == "all":
            labels = [COLLECTOR_LABEL, DASHBOARD_LABEL]
        else:
            return jsonify({"error": f"unknown target: {target}"}), 400
        for label in labels:
            _stop_agent(label)
        return jsonify({"stopped": labels})

    return app


if __name__ == "__main__":  # pragma: no cover
    create_app().run(host="127.0.0.1", port=5137)
