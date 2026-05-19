# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
perl Makefile.PL && make          # build
prove -lv t/                      # all tests
prove -lv t/20-lock_operation.t   # single test
cpanm --installdeps .              # install dependencies
```

Coverage: `cover -test -report Coveralls` (requires `Devel::Cover::Report::Coveralls`).

Set `PRINT_SEGS=1` when running tests to see segment/semaphore counts before and after.

## Architecture

IPC::Shareable exposes System V shared memory via Perl's `tie` interface. Tying a variable returns a "knot" object — all `FETCH`/`STORE` calls go through it transparently.

### Three layers

- **`lib/IPC/Shareable.pm`** — the entire public API: tie magic methods, locking, serialization, segment registration, and all user-facing methods.
- **`lib/IPC/Shareable/SharedMem.pm`** — thin OOP wrapper around `shmget`/`shmread`/`shmwrite`.
- **`IPC::Semaphore`** (CPAN) — one 4-slot semaphore set per segment: `SEM_MARKER` (segment-exists flag), `SEM_READERS`, `SEM_WRITERS`, `SEM_PROTECTED`.

### Knot object fields

| Field | Purpose |
|---|---|
| `_shm` | `IPC::Shareable::SharedMem` handle |
| `_sem` | `IPC::Semaphore` handle (same SysV key as segment) |
| `_key` | Integer SysV IPC key |
| `_lock` | Current lock flags (0 = unlocked) |
| `_data` | Decoded in-memory cache; populated on `lock()` or unlocked `FETCH` |
| `_was_changed` | Set by `STORE` under a lock; triggers write-back on `unlock()` |
| `attributes` | User options hashref (serializer, destroy, size, …) |

Two module-level hashes: `%global_register` (all segments seen by this process) and `%process_register` (segments this process created — used by `clean_up`/`clean_up_all`).

### Locking model

`lock(LOCK_EX)` runs `semop` on the knot's semaphore then decodes the segment into `_data`. All `FETCH`/`STORE` calls while locked use the `_data` cache. `unlock()` encodes and writes `_data` back only if `_was_changed`, then releases the semaphore. Each knot has its **own independent semaphore** — locking a parent does not affect child segment semaphores.

`%semop_args` at the top of `Shareable.pm` defines the exact semaphore operation sequences for each lock-flag combination. `LOCK_EX` waits for both `SEM_READERS` and `SEM_WRITERS` to reach 0 before setting `SEM_WRITERS = 1`. `LOCK_SH` waits for `SEM_WRITERS = 0` then increments `SEM_READERS`.

### Nested data and `_magic_tie`

When a reference is `STORE`d, `STORE` calls `_need_tie()` to check whether the value is already a tied `IPC::Shareable` segment. If not, `_magic_tie` creates a new child segment+semaphore (random SysV key), ties the reference to it, and copies the data in. The parent stores only a placeholder pointing at the child key.

- **JSON serializer**: placeholders are `{"__ics__": {type, child_key_hex}}` objects embedded in the serialized blob. `_decode_json_restore()` walks the decoded structure and re-attaches child segments.
- **Storable serializer**: child references are detected at re-attach time via `tied()` checks.

`_is_child()` checks whether a Perl ref is already tied to an `IPC::Shareable` knot.

### Serializers

Configured per-tie: `serializer => 'json'` (default since v1.14_07) or `serializer => 'storable'`. JSON is cross-platform and portable; Storable is faster but not portable across Perl versions. If JSON decode fails on a segment that was written with Storable, the module falls back automatically with a warning.

### Test numbering convention

`t/` is numbered by feature area: 00–06 setup/keys, 10–18 variable types, 20–28 locking, 30–48 nested segments, 49–67 edge cases, 70–80 internals, 90–99 POD/manifest. Fork tests use `Test::SharedFork`. Segment/semaphore leak checks via `seg_count()`/`sem_count()` bookend most test files.
