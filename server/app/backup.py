"""Backups (SERVER-SPEC §11): SQLite online backup + assets into data/backups/<date>/, keep 14."""

from __future__ import annotations

import asyncio
import logging
import shutil
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

from .config import Settings

log = logging.getLogger("rocky.backup")


def run_backup(settings: Settings, now: datetime | None = None) -> Path:
    now = (now or settings.clock()).astimezone()  # server-local date for the folder name
    target = settings.backups_dir / now.strftime("%Y-%m-%d")
    tmp = settings.backups_dir / f".{now.strftime('%Y-%m-%d')}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    (tmp / "assets").mkdir(parents=True)
    src = sqlite3.connect(settings.db_path, timeout=30)
    try:
        dst = sqlite3.connect(tmp / "rocky.db")
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    if settings.assets_dir.is_dir():
        for f in settings.assets_dir.iterdir():
            if f.is_file() and not f.name.startswith("."):
                shutil.copy2(f, tmp / "assets" / f.name)
    if target.exists():
        shutil.rmtree(target)
    tmp.rename(target)
    prune(settings.backups_dir, settings.backup_keep)
    return target


def prune(backups_dir: Path, keep: int) -> None:
    dirs = sorted(d for d in backups_dir.iterdir() if d.is_dir() and not d.name.startswith("."))
    for d in dirs[:-keep] if keep > 0 else dirs:
        shutil.rmtree(d)


async def nightly(settings: Settings) -> None:
    """Background task: one backup per night at `backup_hour` (server local time)."""
    while True:
        now = datetime.now().astimezone()
        nxt = now.replace(hour=settings.backup_hour, minute=0, second=0, microsecond=0)
        if nxt <= now:
            nxt += timedelta(days=1)
        await asyncio.sleep((nxt - now).total_seconds())
        try:
            path = await asyncio.to_thread(run_backup, settings)
            log.info("backup written to %s", path)
        except Exception:  # noqa: BLE001 - keep the loop alive
            log.exception("backup failed")
