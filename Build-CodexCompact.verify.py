import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess


DATABASES = {
    "state": "migrations",
    "logs": "logs_migrations",
    "goals": "goals_migrations",
    "memories": "memory_migrations",
    "queue": "queue_migrations",
    "thread_history": "thread_history_migrations",
}


def snapshot_schemas(source, home, probe):
    total = 0
    for prefix, directory in DATABASES.items():
        files = {int(p.name.split("_")[0]): p for p in (source / "codex-rs" / "state" / directory).glob("*.sql")}
        if not files:
            raise RuntimeError(f"Missing source migrations: {directory}")
        matches = [p for p in home.glob(f"{prefix}_*.sqlite") if p.stem.removeprefix(prefix + "_").isdigit()]
        if not matches:
            continue
        db = max(matches, key=lambda p: int(p.stem.removeprefix(prefix + "_")))
        with sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=5) as original:
            original.execute("BEGIN")
            applied = original.execute("SELECT version, checksum FROM _sqlx_migrations").fetchall()
            for version, checksum in applied:
                if version not in files:
                    if version <= max(files):
                        raise RuntimeError(f"Missing migration {version} for {db.name}")
                    continue
                if hashlib.sha384(files[version].read_bytes()).digest() != checksum:
                    raise RuntimeError(f"Migration checksum mismatch: {db.name} migration {version}")
                total += 1
            if probe:
                with sqlite3.connect(probe / db.name) as target:
                    schema = original.execute("SELECT type, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END").fetchall()
                    for _, sql in schema:
                        target.execute(sql)
                    rows = original.execute("SELECT * FROM _sqlx_migrations").fetchall()
                    if rows:
                        placeholders = ",".join("?" for _ in rows[0])
                        target.executemany(f"INSERT INTO _sqlx_migrations VALUES ({placeholders})", rows)
                    target.execute(f"PRAGMA user_version = {original.execute('PRAGMA user_version').fetchone()[0]}")
    print(f"Verified {total} applied migration checksums against read-only databases.", flush=True)


async def startup(binary, probe):
    environment = dict(os.environ, CODEX_HOME=str(probe), CODEX_SQLITE_HOME=str(probe), RUST_LOG="error")
    (probe / "config.toml").write_text('[analytics]\nenabled = false\n[feedback]\nenabled = false\n', encoding="utf-8")
    stderr_path = probe / "app-server.stderr.log"
    with stderr_path.open("wb") as stderr:
        process = await asyncio.create_subprocess_exec(str(binary), "-c", "sqlite_home=" + json.dumps(str(probe)), "app-server", "--stdio", cwd=probe, env=environment, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=stderr, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        async def request(identifier, method, params):
            process.stdin.write((json.dumps({"id": identifier, "method": method, "params": params}) + "\n").encode())
            await process.stdin.drain()
            while True:
                line = await process.stdout.readline()
                if not line:
                    raise RuntimeError(f"App-server exited before {method}: {stderr_path.read_text(errors='replace')[-4000:]}")
                event = json.loads(line)
                if event.get("id") == identifier:
                    if "error" in event:
                        raise RuntimeError(f"{method} failed: {event['error']}")
                    return event
        try:
            await asyncio.wait_for(request(1, "initialize", {"clientInfo": {"name": "compact_build_probe", "version": "1.0.0"}, "capabilities": {"experimentalApi": True}}), timeout=45)
            process.stdin.write(b'{"method":"initialized","params":{}}\n')
            await process.stdin.drain()
            await asyncio.wait_for(request(2, "thread/list", {"limit": 1}), timeout=45)
            print("PASS: app-server initialized and thread/list succeeded with existing migration metadata.", flush=True)
        finally:
            process.stdin.close()
            try:
                await asyncio.wait_for(process.wait(), timeout=15)
            except asyncio.TimeoutError:
                process.terminate()
                await process.wait()
    errors = stderr_path.read_text(errors="replace")
    if "previously applied but has been modified" in errors or "failed to migrate" in errors:
        raise RuntimeError(f"Migration failure in startup log: {errors[-4000:]}")


parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("home", type=Path)
parser.add_argument("--binary", type=Path)
parser.add_argument("--probe", type=Path)
args = parser.parse_args()
if args.binary and not args.probe:
    parser.error("--binary requires --probe")
if args.probe:
    args.probe.mkdir(parents=True, exist_ok=False)
snapshot_schemas(args.source.resolve(), args.home.resolve(), args.probe.resolve() if args.probe else None)
if args.binary:
    asyncio.run(startup(args.binary.resolve(), args.probe.resolve()))
