from __future__ import annotations

import re
import subprocess
from datetime import datetime

from . import store
from .paths import db_path

_LINE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}).*?Charge:?\s*(\d+)",
    re.MULTILINE,
)


def parse_log(text: str) -> list:
    """Parse `pmset -g log` lines into coarse backfill sample rows."""
    rows = []
    for m in _LINE.finditer(text):
        dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S %z")
        rows.append({"ts": int(dt.timestamp()), "charge_pct": int(m.group(2)),
                     "source": "backfill"})
    return rows


_EMPTY = {c: None for c in store._COLS}


def apply(conn, text: str) -> int:
    rows = parse_log(text)
    for r in rows:
        store.insert_sample(conn, {**_EMPTY, **r})
    return len(rows)


def main() -> None:  # pragma: no cover
    conn = store.connect(db_path())
    store.init_db(conn)
    text = subprocess.run(
        ["pmset", "-g", "log"], capture_output=True, text=True
    ).stdout
    n = apply(conn, text)
    print(f"[macjuice] backfilled {n} rows")


if __name__ == "__main__":  # pragma: no cover
    main()
