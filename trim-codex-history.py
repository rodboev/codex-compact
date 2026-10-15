"""Delete Codex conversations older than 24 hours. Pinned threads are kept.

Removes old rollout files under ~/.codex/sessions, their rows in state_5.sqlite
and thread_history_1.sqlite, then vacuums both databases to give the space back.
Run: python trim-codex-history.py [hours]
"""
import os
import sqlite3
import sys
import time
from pathlib import Path

HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 24
CODEX = Path.home() / ".codex"
SESSIONS = CODEX / "sessions"
cutoff = time.time() - HOURS * 3600


def connect(name):
    db = sqlite3.connect(CODEX / name, timeout=60)
    db.execute("PRAGMA busy_timeout=60000")
    db.execute("PRAGMA foreign_keys=ON")
    return db


def norm(p):
    return os.path.normcase(p.removeprefix("\\\\?\\"))


def size(path):
    return sum(f.stat().st_size for f in path.parent.glob(path.name + "*"))


state = connect("state_5.sqlite")
keep_rows = state.execute("select id, rollout_path from threads where updated_at >= ? or is_pinned = 1", (cutoff,)).fetchall()
old_ids = [r[0] for r in state.execute("select id from threads where updated_at < ? and is_pinned = 0", (cutoff,))]
keep_ids = {r[0] for r in keep_rows}
keep_paths = {norm(r[1]) for r in keep_rows}

# Rollout files: old by mtime and not owned by a thread we keep.
freed = 0
removed_files = 0
for f in SESSIONS.rglob("*.jsonl"):
    if f.stat().st_mtime >= cutoff or norm(str(f)) in keep_paths or any(i in f.name for i in keep_ids):
        continue
    try:
        n = f.stat().st_size
        f.unlink()
        freed += n
        removed_files += 1
    except OSError as e:
        print(f"skip {f}: {e}")
for d in sorted(SESSIONS.rglob("*"), key=lambda p: len(p.parts), reverse=True):
    if d.is_dir() and not any(d.iterdir()):
        d.rmdir()

before = size(CODEX / "state_5.sqlite") + size(CODEX / "thread_history_1.sqlite")

with state:
    state.execute("create temp table old(id text primary key)")
    state.executemany("insert into old values (?)", ((i,) for i in old_ids))
    state.execute("delete from thread_spawn_edges where parent_thread_id in (select id from old) or child_thread_id in (select id from old)")
    state.execute("delete from threads where id in (select id from old)")

hist = connect("thread_history_1.sqlite")
with hist:
    hist.execute("create temp table old(id text primary key)")
    hist.executemany("insert into old values (?)", ((i,) for i in old_ids))
    for t in ("thread_items", "thread_turns", "thread_realtime_items", "thread_history_projection_state"):
        hist.execute(f"delete from {t} where thread_id in (select id from old)")
    # Rows for threads the state db no longer knows about.
    stale = [(i,) for (i,) in hist.execute("select distinct thread_id from thread_turns").fetchall() if i not in keep_ids]
    hist.executemany("insert or ignore into old values (?)", stale)
    for t in ("thread_items", "thread_turns", "thread_realtime_items", "thread_history_projection_state"):
        hist.execute(f"delete from {t} where thread_id in (select id from old)")

for db, name in ((state, "state_5"), (hist, "thread_history_1")):
    free = db.execute("pragma freelist_count").fetchone()[0] * db.execute("pragma page_size").fetchone()[0]
    try:
        if free > 100e6:
            db.execute("VACUUM")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except sqlite3.OperationalError as e:
        print(f"vacuum {name} failed ({e}); close Codex and rerun to reclaim database space")
    db.close()
    # Codex may hold the file open; a fresh checkpoint lets the shrink land.
    sqlite3.connect(CODEX / f"{name}.sqlite", timeout=60).execute("PRAGMA wal_checkpoint(TRUNCATE)").connection.close()

after = size(CODEX / "state_5.sqlite") + size(CODEX / "thread_history_1.sqlite")
freed += max(before - after, 0)
print(f"kept {len(keep_ids)} threads, removed {len(old_ids)} threads and {removed_files} rollout files, freed {freed / 1e9:.1f} GB")
