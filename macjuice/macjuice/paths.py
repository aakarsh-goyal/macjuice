import os
import pathlib


def db_path() -> pathlib.Path:
    """Resolve the single DB file both processes use."""
    override = os.environ.get("MACJUICE_DB")
    if override:
        path = pathlib.Path(override).expanduser()
    else:
        path = (
            pathlib.Path.home()
            / "Library"
            / "Application Support"
            / "macjuice"
            / "battery.db"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    return path
