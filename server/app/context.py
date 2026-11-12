"""Service container shared by the REST API, admin, MCP and CLI."""

from __future__ import annotations

from dataclasses import dataclass

from .catalog import CatalogStore
from .config import Settings
from .db import Database
from .images import AssetStore
from .records import RecordStore
from .tokens import Token, TokenStore


@dataclass
class AppContext:
    settings: Settings
    db: Database
    tokens: TokenStore
    assets: AssetStore
    catalog: CatalogStore
    records: RecordStore

    @classmethod
    def open(cls, settings: Settings) -> AppContext:
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        db = Database(settings.db_path)
        assets = AssetStore(db, settings.assets_dir, settings.clock)
        return cls(
            settings=settings,
            db=db,
            tokens=TokenStore(db, settings.clock),
            assets=assets,
            catalog=CatalogStore(db, settings.clock, assets.exists),
            records=RecordStore(db, settings.clock),
        )


def bearer_token(headers, ctx: AppContext) -> tuple[Token | None, bool]:
    """(token, header_present) from an `Authorization: Bearer …` header."""
    raw = headers.get("authorization")
    if not raw:
        return None, False
    scheme, _, secret = raw.partition(" ")
    if scheme.lower() != "bearer" or not secret.strip():
        return None, True
    return ctx.tokens.verify(secret.strip()), True
