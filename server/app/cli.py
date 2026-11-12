"""`rocky-admin` CLI (SERVER-SPEC §11): token create|list|revoke, audit, backup, export-catalog.

Run inside the container: `docker compose exec rocky rocky-admin token create --scope device --name iphone`.
"""

from __future__ import annotations

import argparse
import json
import sys

from .backup import run_backup
from .config import Settings
from .context import AppContext
from .errors import AppError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="rocky-admin", description="Rocky server administration")
    sub = parser.add_subparsers(dest="cmd", required=True)

    token = sub.add_parser("token", help="access tokens").add_subparsers(dest="action", required=True)
    create = token.add_parser("create", help="create a token (the secret is printed once)")
    create.add_argument("--scope", required=True, choices=["device", "agent", "admin"])
    create.add_argument("--name", required=True)
    token.add_parser("list", help="list tokens")
    revoke = token.add_parser("revoke", help="revoke a token (ends its admin sessions)")
    revoke.add_argument("name")

    audit = sub.add_parser("audit", help="show the audit log (newest first)")
    audit.add_argument("--limit", type=int, default=50)

    sub.add_parser("backup", help="write a backup to data/backups/<date>/ now")

    export = sub.add_parser("export-catalog", help="print the catalog JSON (live or a given revision)")
    export.add_argument("--revision", type=int)

    args = parser.parse_args(argv)
    settings = Settings.from_env()
    ctx = AppContext.open(settings)
    try:
        ctx.catalog.seed_if_empty(settings.seed_path)
        if args.cmd == "token":
            if args.action == "create":
                secret = ctx.tokens.create(args.name, args.scope)
                print(f"Token {args.name!r} ({args.scope}) created. Copy it now, it is not shown again:")
                print(secret)
            elif args.action == "list":
                rows = ctx.tokens.list()
                print(f"{'NAME':<24} {'SCOPE':<7} {'CREATED':<21} {'LAST USED':<21} REVOKED")
                for r in rows:
                    print(f"{r['name']:<24} {r['scope']:<7} {r['created_at']:<21} {r['last_used_at'] or '-':<21} "
                          f"{r['revoked_at'] or '-'}")
            elif args.action == "revoke":
                if not ctx.tokens.revoke(args.name):
                    print(f"no token named {args.name!r}", file=sys.stderr)
                    return 1
                print(f"Token {args.name!r} revoked.")
        elif args.cmd == "audit":
            with ctx.db.read() as conn:
                rows = conn.execute(
                    "SELECT at, token, action, target, ref FROM audit ORDER BY id DESC LIMIT ?", (args.limit,)
                ).fetchall()
            for r in rows:
                print(f"{r['at']}  {r['token']:<20} {r['action']:<28} {r['target'] or '-':<45} {r['ref'] or ''}")
        elif args.cmd == "backup":
            print(run_backup(settings))
        elif args.cmd == "export-catalog":
            data = ctx.catalog.revision_wire(args.revision) if args.revision else ctx.catalog.current_wire()
            print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
    except AppError as exc:
        print(f"error: {exc.detail}", file=sys.stderr)
        return 1
    finally:
        ctx.db.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
