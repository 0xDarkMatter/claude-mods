# Testing Against SQLite

SQLite is unusually pleasant to test against: a whole database is one file (or none at all),
so isolation is cheap and setup is fast. The traps are the ways a test database quietly
stops resembling production.

## Contents

- [In-memory vs file databases](#in-memory-vs-file-databases)
- [Keeping the test database honest](#keeping-the-test-database-honest)
- [Fixture strategies](#fixture-strategies)
- [Deterministic seeding](#deterministic-seeding)
- [Testing migrations](#testing-migrations)
- [Testing concurrency](#testing-concurrency)
- [Testing query plans](#testing-query-plans)
- [Testing against D1](#testing-against-d1)

---

## In-memory vs file databases

```python
sqlite3.connect(":memory:")                                     # private to this connection
sqlite3.connect("file:test?mode=memory&cache=shared", uri=True) # shared across connections
sqlite3.connect("/tmp/test-xyz.db")                             # real file
```

| | `:memory:` | Shared-cache memory | Temp file |
|---|---|---|---|
| Speed | Fastest | Fast | Fast enough (OS page cache) |
| Multiple connections see it | **No** | Yes | Yes |
| Supports WAL | **No** (WAL needs a real file) | No | **Yes** |
| Survives the process | No | No | Yes — inspectable after a failure |
| Matches production behaviour | Least | Middling | **Most** |

**Recommendation: temp files, not `:memory:`.** The speed difference is negligible against
the OS page cache, and a file test can exercise WAL, real locking, multiple connections, and
`busy_timeout` — precisely the behaviours where SQLite bugs live. A file also survives a
failing test, so you can open it and look.

```python
import tempfile, pathlib, sqlite3, pytest

@pytest.fixture
def db_path(tmp_path: pathlib.Path) -> str:
    return str(tmp_path / "test.db")     # pytest deletes tmp_path automatically
```

Reserve `:memory:` for pure-SQL unit tests where a single connection is genuinely the whole
story.

---

## Keeping the test database honest

The recurring failure is a test database configured differently from production, so tests
pass on behaviour production doesn't have. **Use the same connection factory in tests as in
production** — do not hand-roll a second one.

```python
# app/db.py — one factory, used by prod and tests alike
def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA foreign_keys = ON")
    return conn
```

| Divergence | Consequence |
|---|---|
| `foreign_keys` on in prod, off in tests (or vice versa) | FK violations either pass tests and fail live, or the reverse |
| WAL in prod, rollback in tests | Locking behaviour differs; concurrency bugs invisible |
| STRICT tables in prod, loose in tests | Type errors slip through |
| Tiny test dataset | Every plan is a scan and every scan is fast — **no performance signal at all** |
| Schema built by a fixture instead of by migrations | Tests validate a schema that never exists in production |

**Build the test schema by running your real migrations.** That way the migration path is
tested on every run, and the tested schema is by construction the one production will have.

---

## Fixture strategies

| Strategy | Speed | Isolation | Use when |
|---|---|---|---|
| Fresh database per test | Slowest | Perfect | Small suites; anything touching schema |
| Template copy | Fast | Perfect | Expensive seed data — build once, `shutil.copy` per test |
| Transaction rollback per test | Fastest | Good | Read-heavy tests that don't need their own DDL |
| Truncate between tests | Fast | Good | Stable schema, changing data |

```python
# Template pattern: seed once per session, copy per test - fast AND fully isolated
import shutil, pytest

@pytest.fixture(scope="session")
def template_db(tmp_path_factory):
    path = tmp_path_factory.mktemp("tpl") / "template.db"
    conn = connect(str(path))
    run_migrations(conn)
    seed(conn)
    conn.close()
    return str(path)

@pytest.fixture
def db(template_db, tmp_path):
    path = tmp_path / "test.db"
    shutil.copy(template_db, path)     # copying a CLOSED database is safe
    conn = connect(str(path))
    yield conn
    conn.close()
```

Copying a closed database file is safe — the prohibition on `cp` applies to databases with
active writers (see [`operations.md`](operations.md)). Close the template before copying, or
build it with `VACUUM INTO`.

```python
# Rollback pattern: fastest, but the test cannot commit or run its own DDL
@pytest.fixture
def db(shared_conn):
    shared_conn.execute("BEGIN")
    yield shared_conn
    shared_conn.execute("ROLLBACK")
```

---

## Deterministic seeding

Flaky test data is a self-inflicted wound. Three rules:

1. **Seed the RNG explicitly.** `random.Random(1234)`, never the global module state.
2. **Never use SQL `random()` or `datetime('now')` in fixtures.** Both make the fixture
   non-reproducible and time-dependent — the classic source of a suite that fails at
   midnight or on a leap day.
3. **Fix the clock.** Pass timestamps in as data; don't let the database generate them.

```python
import random

def seed(conn, n: int = 1000, seed_value: int = 1234) -> None:
    rng = random.Random(seed_value)          # local RNG - global state is not test-safe
    base = "2026-01-01T00:00:00Z"            # fixed epoch, not datetime('now')
    rows = [
        (f"org-{rng.randrange(50)}", f"sku-{i:06d}",
         round(rng.uniform(1, 500), 2),
         f"2026-01-{1 + (i % 28):02d}T00:00:00Z")
        for i in range(n)
    ]
    conn.execute("BEGIN IMMEDIATE")
    conn.executemany(
        "INSERT INTO product (org, sku, price, created_at) VALUES (?,?,?,?)", rows)
    conn.execute("COMMIT")
```

**Seed enough rows to produce a performance signal.** A hundred rows makes every plan fast
and every index pointless; if you intend to assert anything about scans or plans, seed tens
of thousands. Generate them — don't commit a large fixture file.

---

## Testing migrations

Migrations are the code most likely to destroy data and least likely to be tested. Assert
three things:

```python
def test_migrations_are_idempotent(db_path):
    conn = connect(db_path)
    run_migrations(conn)
    before = schema_snapshot(conn)
    run_migrations(conn)                       # second run must be a no-op
    assert schema_snapshot(conn) == before

def test_migration_preserves_data(db_path):
    conn = connect(db_path)
    run_migrations(conn, target=3)
    conn.execute("INSERT INTO product (org, sku, price) VALUES ('acme','x',1.0)")
    run_migrations(conn, target=4)             # the migration under test
    row = conn.execute("SELECT org, sku FROM product").fetchone()
    assert (row["org"], row["sku"]) == ("acme", "x")

def test_schema_is_valid_after_migration(db_path):
    conn = connect(db_path)
    run_migrations(conn)
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert conn.execute("PRAGMA foreign_key_check").fetchall() == []


def schema_snapshot(conn) -> list:
    return conn.execute(
        "SELECT type, name, sql FROM sqlite_master ORDER BY type, name").fetchall()
```

The `foreign_key_check` assertion is the one that catches the 12-step recreate dance going
wrong — a rebuilt table that dropped its references still looks fine until something reads
across it. See [`migration-patterns.md`](migration-patterns.md).

---

## Testing concurrency

Concurrency bugs need a **file** database and real connections.

```python
import threading, sqlite3

def test_concurrent_writers_do_not_error(db_path):
    """Two writers with busy_timeout should serialise, not raise."""
    errors = []

    def writer(tag):
        conn = connect(db_path)                # separate CONNECTION, not a shared one
        try:
            for i in range(100):
                conn.execute("BEGIN IMMEDIATE")
                conn.execute("INSERT INTO event (kind) VALUES (?)", (tag,))
                conn.execute("COMMIT")
        except sqlite3.OperationalError as exc:
            errors.append(exc)
        finally:
            conn.close()

    threads = [threading.Thread(target=writer, args=(f"t{i}",)) for i in range(4)]
    for t in threads: t.start()
    for t in threads: t.join()
    assert not errors, f"contention errors: {errors}"
```

To test that your retry logic works, do the opposite: set `busy_timeout = 0`, force a
conflict, and assert the retry wrapper recovers.

---

## Testing query plans

Plans can regress silently — an added column turns a covering index non-covering, and
nothing fails except latency. A plan assertion is a cheap regression guard for the small
number of statements that genuinely matter.

```python
def plan(conn, sql: str, params=()) -> str:
    return "\n".join(r["detail"]
                     for r in conn.execute("EXPLAIN QUERY PLAN " + sql, params))

def test_org_lookup_uses_covering_index(db):
    detail = plan(db, "SELECT DISTINCT product_id FROM q_product WHERE org LIKE ?", ("%acme%",))
    assert "COVERING INDEX" in detail, detail      # the word COVERING is the whole test
    assert "USE TEMP B-TREE" not in detail, detail
```

Keep these to the handful of statements you have actually optimised. Asserting plans across
a whole codebase produces a brittle suite that fails on every legitimate schema change.

`scripts/eqp-triage.py --db <file> --sql "<statement>"` exits `10` when it finds a problem,
which makes it usable directly as a shell-level assertion in CI.

---

## Testing against D1

| Approach | Fidelity | Note |
|---|---|---|
| Local SQLite with the same schema | Good for logic | No rows-read metric, no parameter cap, no `SQLITE_AUTH` restrictions |
| `wrangler d1 execute` **without** `--remote` | Good | Local D1 copy — same wrangler surface, no network |
| Miniflare / `wrangler dev` | Good | Exercises the Workers binding API too |
| A preview/dev D1 database | Highest | The only place to verify platform behaviour (parameter caps, FTS5 availability) |

**Never point tests at the production database.** For the platform-specific behaviours that
only appear remotely — the 100-parameter cap, `SQLITE_AUTH` refusals, real `rows_read` — use
a dedicated preview database and treat those as integration tests, run deliberately rather
than on every commit.

---

## See also

- [`hosts.md`](hosts.md) — the connection factory to share between prod and tests
- [`migration-patterns.md`](migration-patterns.md) — what the migration tests are guarding
- [`query-performance.md`](query-performance.md) — reading the plans you assert on
- [`operations.md`](operations.md) — restore drills as a scheduled test
