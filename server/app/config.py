"""Runtime configuration (environment variables)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable

SERVER_DIR = Path(__file__).resolve().parent.parent


def utcnow() -> datetime:
    return datetime.now(UTC)


def _flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass
class Settings:
    data_dir: Path
    seed_path: Path
    cookie_secure: bool = True
    backups_enabled: bool = True
    backup_hour: int = 3
    backup_keep: int = 14
    mcp_writes_per_hour: int = 30
    session_hours: int = 8
    clock: Callable[[], datetime] = field(default=utcnow)

    @property
    def db_path(self) -> Path:
        return self.data_dir / "rocky.db"

    @property
    def assets_dir(self) -> Path:
        return self.data_dir / "assets"

    @property
    def backups_dir(self) -> Path:
        return self.data_dir / "backups"

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            data_dir=Path(os.environ.get("ROCKY_DATA_DIR", SERVER_DIR / "data")),
            seed_path=Path(os.environ.get("ROCKY_SEED", SERVER_DIR / "seed" / "catalog.json")),
            cookie_secure=_flag("ROCKY_COOKIE_SECURE", True),
            backups_enabled=_flag("ROCKY_BACKUPS", True),
            backup_hour=int(os.environ.get("ROCKY_BACKUP_HOUR", "3")),
        )
