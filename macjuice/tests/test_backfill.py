from macjuice import backfill, store


SAMPLE_LOG = (
    "2026-05-29 15:56:02 +0530 Assertions  Summary- [System: PrevIdle] "
    "Using Batt(Charge: 92)\n"
    "2026-05-29 22:23:15 +0530 Assertions  Summary- [System: ...] "
    "Using Batt(Charge: 20)\n"
    "2026-05-29 22:23:19 +0530 Sleep  Entering Sleep state due to 'Clamshell "
    "Sleep' Using Batt (Charge:20%)\n"
)


def test_parse_log_rows():
    rows = backfill.parse_log(SAMPLE_LOG)
    charges = [r["charge_pct"] for r in rows]
    assert 92 in charges and 20 in charges
    assert all(r["source"] == "backfill" for r in rows)
    assert all(isinstance(r["ts"], int) for r in rows)


def test_backfill_is_idempotent(tmp_path):
    conn = store.connect(tmp_path / "b.db")
    store.init_db(conn)
    backfill.apply(conn, SAMPLE_LOG)
    backfill.apply(conn, SAMPLE_LOG)  # second run must not duplicate
    rows = store.query_range(conn, 0, 2**31)
    backfill_rows = [r for r in rows if r["source"] == "backfill"]
    assert len(backfill_rows) == len({r["ts"] for r in backfill_rows})
