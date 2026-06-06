from __future__ import annotations

import sqlite3

_COLS = [
    "ts", "source", "charge_pct", "current_mah", "max_mah", "design_mah",
    "cycle_count", "max_capacity_reported_pct", "condition", "heavy_ts",
    "temp_c", "voltage_v", "amperage_ma", "watts", "charging", "adapter_watts",
    "time_remaining_min", "serial", "model",
]

_SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
  ts INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  charge_pct REAL, current_mah REAL, max_mah REAL, design_mah REAL,
  cycle_count INTEGER, max_capacity_reported_pct REAL, condition TEXT,
  heavy_ts INTEGER, temp_c REAL, voltage_v REAL, amperage_ma REAL, watts REAL,
  charging INTEGER, adapter_watts REAL, time_remaining_min INTEGER,
  serial TEXT, model TEXT
);
CREATE TABLE IF NOT EXISTS events (
  ts INTEGER NOT NULL, type TEXT NOT NULL, source TEXT NOT NULL, detail TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS self_metrics (
  ts INTEGER PRIMARY KEY,
  collector_cpu_s REAL, dashboard_cpu_s REAL,
  collector_rss_mb REAL, dashboard_rss_mb REAL
);
"""

_SELF_COLS = ["ts", "collector_cpu_s", "dashboard_cpu_s",
              "collector_rss_mb", "dashboard_rss_mb"]


def connect(path) -> sqlite3.Connection:
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def init_db(conn) -> None:
    conn.executescript(_SCHEMA)
    conn.commit()


def insert_sample(conn, sample: dict) -> None:
    vals = [sample.get(c) for c in _COLS]
    placeholders = ",".join("?" * len(_COLS))
    conn.execute(
        f"INSERT OR IGNORE INTO samples ({','.join(_COLS)}) VALUES ({placeholders})",
        vals,
    )
    conn.commit()


def insert_event(conn, ts, type_, source, detail) -> None:
    conn.execute(
        "INSERT INTO events (ts, type, source, detail) VALUES (?,?,?,?)",
        (ts, type_, source, detail),
    )
    conn.commit()


def insert_self_metric(conn, row: dict) -> None:
    vals = [row.get(c) for c in _SELF_COLS]
    placeholders = ",".join("?" * len(_SELF_COLS))
    conn.execute(
        f"INSERT OR IGNORE INTO self_metrics ({','.join(_SELF_COLS)}) "
        f"VALUES ({placeholders})",
        vals,
    )
    conn.commit()


def query_self_metrics(conn, start, end) -> list:
    cur = conn.execute(
        "SELECT * FROM self_metrics WHERE ts BETWEEN ? AND ? ORDER BY ts",
        (start, end),
    )
    return [dict(r) for r in cur.fetchall()]


def query_range(conn, start, end) -> list:
    cur = conn.execute(
        "SELECT * FROM samples WHERE ts BETWEEN ? AND ? ORDER BY ts", (start, end)
    )
    return [dict(r) for r in cur.fetchall()]


def query_events(conn, start, end) -> list:
    cur = conn.execute(
        "SELECT * FROM events WHERE ts BETWEEN ? AND ? ORDER BY ts", (start, end)
    )
    return [dict(r) for r in cur.fetchall()]


def latest(conn) -> dict | None:
    cur = conn.execute("SELECT * FROM samples ORDER BY ts DESC LIMIT 1")
    row = cur.fetchone()
    return dict(row) if row else None


def set_meta(conn, key, value) -> None:
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )
    conn.commit()


def get_meta(conn, key) -> str | None:
    cur = conn.execute("SELECT value FROM meta WHERE key=?", (key,))
    row = cur.fetchone()
    return row[0] if row else None
