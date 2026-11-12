"""rocky-admin CLI and backups."""

from __future__ import annotations

import json
import sqlite3

import pytest

from app import cli
from app.backup import prune, run_backup
from app.config import Settings

from .conftest import SEED


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("ROCKY_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("ROCKY_SEED", str(SEED))
    return tmp_path / "data"


def test_token_commands(env, capsys):
    assert cli.main(["token", "create", "--scope", "device", "--name", "iphone"]) == 0
    out = capsys.readouterr().out
    secret = out.strip().splitlines()[-1]
    assert len(secret) == 43
    assert cli.main(["token", "create", "--scope", "device", "--name", "iphone"]) == 1
    assert "already exists" in capsys.readouterr().err
    assert cli.main(["token", "list"]) == 0
    listing = capsys.readouterr().out
    assert "iphone" in listing and "device" in listing and secret not in listing
    assert cli.main(["token", "revoke", "iphone"]) == 0
    assert cli.main(["token", "revoke", "ghost"]) == 1
    assert cli.main(["audit"]) == 0
    audit = capsys.readouterr().out
    assert "token.revoke" in audit and "token.create" in audit and "catalog.seed" in audit
    with pytest.raises(SystemExit):
        cli.main(["token", "create", "--scope", "root", "--name", "x"])


def test_export_catalog(env, capsys):
    assert cli.main(["export-catalog"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data["revision"] == 1 and data["workouts"][0]["id"] == "A"
    assert cli.main(["export-catalog", "--revision", "7"]) == 1


def test_backup_command_and_retention(env, capsys):
    assert cli.main(["backup"]) == 0
    path = capsys.readouterr().out.strip()
    db = sqlite3.connect(f"{path}/rocky.db")
    assert db.execute("SELECT COUNT(*) FROM catalog_revisions").fetchone()[0] == 1
    db.close()


def test_backup_copies_assets_and_prunes(settings, ctx, clock, admin):
    from .conftest import png_bytes

    sha = admin.api("POST", "/admin/api/assets", files={"file": ("a.png", png_bytes(), "image/png")}).json()["sha256"]
    for day in range(16):
        clock.advance(days=1)
        target = run_backup(settings)
    dirs = sorted(p.name for p in settings.backups_dir.iterdir())
    assert len(dirs) == 14 and dirs[-1] == target.name == "2026-11-28"
    assert (target / "assets" / sha).read_bytes() == (settings.assets_dir / sha).read_bytes()
    # same day again replaces the backup
    run_backup(settings)
    assert len(list(settings.backups_dir.iterdir())) == 14
    prune(settings.backups_dir, 3)
    assert len(list(settings.backups_dir.iterdir())) == 3


def test_settings_from_env(monkeypatch, tmp_path):
    monkeypatch.setenv("ROCKY_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("ROCKY_COOKIE_SECURE", "0")
    s = Settings.from_env()
    assert s.data_dir == tmp_path and s.cookie_secure is False and s.db_path == tmp_path / "rocky.db"
