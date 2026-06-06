# Plan: Pre-serialized single-segment scalar storage

> **NEXT ACTION:** Proceed with V2 — `_encode` raw branch (identity write + size guard + ref croak)
> **LAST SESSION:** V1 ✅ — `serializer => 'raw'` recognized; `_parse_args` now validates json/storable/raw (bogus croaks)
> **ARCHIVE:** See pre-serialized-archive.md for completed V1

## Objective

Let a caller **pre-serialize an entire data structure themselves** (e.g. `encode_json(\%big)`),
hand the resulting string to a **scalar tie**, and have IPC::Shareable store the whole
thing in **one** shared-memory segment — bypassing our serializer on the way in.

The open question from the user, answered below in **Design decision #1**: do we also
bypass our *de*serializer on the way out and let the user decode? **Yes — the read side
is a symmetric bypass.** We return the stored bytes verbatim; the user calls `decode_json`
(or whatever they used) themselves.

## Why this is worth doing

A normal `tie %h` / `tie @a` with nested refs **fans out**: every nested hashref/arrayref/
scalarref becomes its own child tie via `_magic_tie` (`lib/IPC/Shareable.pm:1708`), each
with its own shm segment **and** semaphore set, wired together by `__ics__` markers
(`_encode_json_prepare`, `:1292`). A deep structure therefore consumes many segments +
semaphores, multiplies syscalls, stresses `SHMMNI`/`SEMMNI`, and forces whole-tree locking
(`_lock_children`, `:1849`).

Pre-serializing to a single string and storing it through a **scalar** tie collapses an
arbitrarily deep structure into **exactly one segment + one semaphore**. We trade away
nested shared-mutation and per-child locking for: drastically fewer IPC resources, far
fewer syscalls, lower per-op overhead, and no `__ics__`/reattach machinery.

## Design notes (the "what would it take" investigation)

### Current scalar path (for reference)

- **Write:** `STORE` TYPE_SCALAR (`:192`) → `_write_to_seg` (`:1819`) → `_encode` (`:1249`)
  → `_encode_json` (`:1278`) → `_encode_json_prepare` wraps the scalar as
  `{ '__sv__' => $val }` (`:1352`) → `encode_json` → prepend 14-byte `IPC::Shareable`
  tag → size check → `shmwrite`.
- **Read:** `FETCH` TYPE_SCALAR (`:233`) → `_decode` (`:1260`) → `_decode_json` (`:1357`)
  → strip 14-byte tag (`:1370`) → `decode_json` → unwrap `{__sv__}` / `{__ics__}`
  (`:1383-1394`) → return `\$val`.

So a user-supplied JSON string today gets **double-encoded**: escaped inside
`{"__sv__":"…escaped…"}` on write (every `"` → `\"`, inflating size and risking the
segment-size croak) and fully `decode_json`'d on read. The whole point of this feature is
to skip both.

### Design decision #1 — symmetric bypass (answers the user's question)

On read we **return the raw bytes and let the user decode**. We do *not* auto-decode for
them. Rationale:

1. A SCALAR tie must return a scalar. Auto-inflating JSON into a hashref would return a
   **detached, non-shared** structure (mutations wouldn't propagate) and breaks the tie's
   mental model.
2. Auto-decoding re-incurs the exact `decode_json` cost we set out to avoid — the biggest
   single win of this feature is skipping decode on every read.
3. The user owns the schema (they encoded it), so they are the right party to decode.

The only bytes we touch are our own 14-byte `IPC::Shareable` ownership tag (added on write,
stripped on read). Everything between the tag and the trailing NUL padding is the user's.

### Design decision #2 — explicit `serializer => 'raw'` mode (primary mechanism)

Implement an **identity serializer**, selected with `serializer => 'raw'`, that slots into
the existing `_encode`/`_decode` dispatch (which already branches on the `serializer`
attribute, `:1252` / `:1263`):

- `_encode` (raw): write `'IPC::Shareable' . $$data`, keep the existing size-vs-segment
  croak. Croak if the stored value is a **ref** (raw expects a pre-serialized string, not a
  structure).
- `_decode` (raw): verify the 14-byte tag, return `\substr($bytes, 14)`; empty/untagged
  segment → `undef` (mirrors `_decode`'s empty-scalar default, `:1276`).

We **keep the 14-byte tag** so `shm_segments()` (`:722`), `clean_up_testing` (`:1168`),
and foreign-segment detection still recognize the segment as ours. Both ends must configure
`serializer => 'raw'` — exactly the same expectation that already exists for json-vs-storable
(there is no fully reliable in-band auto-detection today; only the one-way storable fallback
at `:1631-1660`).

Why a `serializer` value and not a separate boolean: it reuses the existing dispatch, it is
mutually exclusive with json/storable by construction (no "raw + storable?" confusion), and
it reads naturally as "the user owns serialization."

### Design decision #3 — auto-sensing on the json serializer (in scope: V8–V10)

The original framing ("sense whether the data is already JSON serialized and bypass") is a
**convenience layer** on top of the json serializer. Per the user's decision ("Raw +
auto-sense now") it ships in this pass as V8–V10, alongside the explicit `raw` mode. It is
controlled by a new `detect_serialized` attribute, **default on**, with an off switch for
callers who need byte-identical legacy segments. Design basis:

- A json-mode reader cannot tell "wrapped `{__sv__}`" from "raw passthrough" without an
  **in-band marker**. Normal encoded bodies always begin with `{` or `[` (because
  `_encode_json_prepare` always returns a ref or an `__sv__` hash), so a one-byte sentinel
  that is neither `{`/`[` nor NUL (NUL would trip `SharedMem::data()`'s truncation at
  `:181`) — e.g. `\x1e` — placed right after the 14-byte tag disambiguates cleanly and stays
  backward-compatible (old segments → `{`/`[` → normal path).
- Detection policy options: (A) broad `eval { decode_json($val); 1 }` — also matches bare
  numbers/booleans/null and costs a full parse per store; (B) narrow: defined, non-ref,
  `m/^\s*[\[{]/ && m/[\]}]\s*$/`, then validate — targets real pre-encoded structures and
  avoids number-vs-string flattening; (C) skip validation entirely and trust the structural
  sniff (correctness doesn't depend on validity because our decode never re-parses a raw
  payload — only an external reader expecting valid JSON would care).
- Key safety insight: for any **string** value, raw passthrough is observationally identical
  to the current `__sv__` path (string in → same string out), so a detection false positive
  never corrupts a round-trip — it only changes segment bytes. The exception is bare numeric/
  boolean scalars (JSON number `42` vs string `"42"`), which is exactly why policy B excludes
  non-container values.

### Edge cases / constraints (apply to the `raw` V-tasks)

- **Refs in raw mode:** croak with a clear message ("raw serializer expects a pre-serialized
  string"). `_magic_tie`/`_need_tie` are ref-gated and won't fire for strings.
- **Segment sizing:** the whole blob lives in one segment, so the caller must set `size`
  large enough. The existing `length > $seg->size` croak (`:1286`/`:1482`) is the guard.
  This is a real tradeoff vs. the fan-out approach (which spreads data across segments).
- **Concurrency granularity:** updates are whole-blob replace; there is no nested tie magic
  and no per-child locking. Document; this is intentional (see "Explicitly NOT doing").
- **NUL bytes:** `_decode` for raw should read via `shmread` and strip only trailing NUL
  padding, *not* truncate at the first NUL (`SharedMem::data()` truncates at first NUL,
  `:181`). JSON text is NUL-free, but be explicit so binary-ish payloads aren't silently cut.
- **`_tie` post-attach (`:1629-1663`):** add a `raw` branch that just sets
  `$knot->{_data} = $knot->_decode($seg)` and skips the json/storable fallback dance.
- **Introspection:** `shm_segments()` child-key regex won't false-match (no children) unless
  a raw payload literally contains `"child_key_hex":"…"` — a pre-existing theoretical class
  of issue, not a regression; note it.

### Edge-case & test matrix (drives V6, V10, V11)

The user wants exhaustive coverage. Every input type below is exercised in **both** the
explicit `raw` mode and the json **auto-sense** mode.

**Input value types**
- Valid JSON object string `{"a":1}`, array string `[1,2,3]`, deep/nested object, object
  with unicode/wide chars (UTF-8 octets).
- Valid JSON scalars: `42`, `3.14`, `-7`, `"x"`, `true`, `false`, `null`.
- Non-JSON strings: `hello`, empty `''`, whitespace `'   '`, JSON with leading/trailing
  whitespace.
- JSON-looking but invalid: `{bad`, `{"a":}`, `[1,2,`, `{"a":1}trailing`.
- Numbers: IV `42`, NV `3.14`, negative, large.
- `undef`.
- **Refs (the user's "object, cref" cases):** blessed object, code ref (`sub {}`), glob ref
  (`\*STDOUT`), regexp ref (`qr/x/`), unblessed hashref / arrayref / scalarref, and an
  existing IPC::Shareable tied child.
- **Payload-content hazards:** string containing the literal 14-byte tag `IPC::Shareable`,
  the sentinel byte `\x1e`, a NUL `\x00`, the literal text `__sv__` / `__ics__` /
  `"child_key_hex":"…"`; near-`size` and over-`size` payloads (over → croak).

**Expected behavior**
- **raw mode:** any value that `ref()`s (object, cref, glob, regexp, plain ref, tied child)
  → **croak** with a clear "raw serializer expects a pre-serialized string" message. A
  string round-trips **byte-identical** (locked + unlocked FETCH, cross-process). Exactly
  one segment is created (`seg_count` delta == 1).
- **json auto-sense ON:** only a defined, non-ref, container-shaped, *valid* JSON string
  takes the sentinel fast path; everything else (numbers, bools, `null`, plain/invalid
  strings, and **all refs**) takes the existing `{__sv__}` path. Crucially, detection is
  ref-gated, so storing an **object** or a **cref** behaves **exactly as today**: a blessed
  object is serialized via `-convert_blessed_universally` (`:23`); a cref croaks inside
  `encode_json` as it does now. We must prove auto-sense does not alter either.
- **json auto-sense OFF** (`detect_serialized => 0`): byte-identical legacy `{__sv__}`
  output — a regression guard.
- **Backward / cross-version:** new code reads old `{__sv__}` / `{__ics__}` segments fine;
  a sentinel segment is **not** readable by a pre-feature IPC::Shareable (it would
  `decode_json` the `\x1e` and die) — documented caveat, not a code path we can fix.

**Param validation**
- `serializer`: `json` / `storable` / `raw` accepted; anything else croaks.
- `raw` is **SCALAR-only**: `var => 'HASH'|'ARRAY'` + `serializer => 'raw'` croaks.
- `detect_serialized`: truthy/falsey accepted; **inert** for non-json serializers (document;
  no croak when combined with storable/raw).
- `size` too small for the blob → croak (existing guard, `:1286`/`:1482`).

## Execution rules

- **One task per turn**: when told to proceed or continue (or "next", "go", etc.), perform only the next ⏳ V task listed, then stop and wait for further instruction. Do NOT batch multiple V tasks per turn unless the user explicitly authorizes a batch (e.g., "do V1-V3", "do all the style fixes").

## Maintenance rules

- V task ✅: do all three:
  1. Set Actual to `✅ YYYY-MM-DD attempt N: PASS`.
  2. Append a new bullet at the bottom of pre-serialized-archive.md's "Archived V Tasks" section: `- V#: description — ✅ YYYY-MM-DD attempt N: PASS`. One bullet per entry — never run two entries together.
  3. **Delete the V# row from this file's Validation Table.**
- V task ❌: update Actual with `❌ YYYY-MM-DD attempt N: reason`. Rerun same V# with attempt N+1. Do NOT create a new V#.
- Update ARCHIVE pointer to reflect what's archived (e.g., `V1-V2` → `V1-V3`)
- Update NEXT ACTION to next ⏳ row; update LAST SESSION
- Never renumber within a series. New items get next free number.
- **Discovery triage during V# work** — when you find something while working a V task, classify before continuing:
  - Blocks the current V task → add `Fix N: problem discovered during V# — [what + fix]` to `## Discovery Tracking`; resolve as part of this V task's work.
  - Real bug but doesn't block this V task → add a new V# row (next free) to the Validation Table with ⏳; do not detour to fix it now.
  - Non-blocking improvement → add new B# to `## Backlog` (one `B#` per line, each separated by a blank line — never run two entries together, or Markdown collapses them into a single mashed paragraph).
  - Decided not to do → add to `## Explicitly NOT doing` with a one-line justification.
- Move resolved fixes to archive's "Archived Fixes" section; keep only unresolved in main Discovery Tracking
- To promote a backlog item to an active task: assign it the next free V# (e.g., B3 becomes V4) and move to the Validation Table. The B# slot is retired and never reused.

## Validation Table

| ID | What | Command | Expected | Actual |
|----|------|---------|----------|--------|
| V2 | `_encode` raw branch: write `'IPC::Shareable'.$$data` with size guard; croak when the stored value is a ref | one-liner stores `'{"a":1}'` then dumps raw segment bytes via `seg->shmread` | segment bytes == `IPC::Shareable{"a":1}` (no `__sv__`, no escaping); storing a hashref croaks | ⏳ |
| V3 | `_decode` raw branch: verify tag, return `\substr(bytes,14)` stripping only trailing NULs; empty/untagged → undef | store then FETCH the scalar, both unlocked and under `shlock(LOCK_SH)` | FETCH returns byte-identical `'{"a":1}'` in both cases; fresh segment FETCHes undef | ⏳ |
| V4 | `_tie` raw post-attach branch + cross-process attach; ref-store guard | proc A creates+stores raw blob; proc B attaches `create=>0, serializer=>'raw'` and reads | proc B reads identical bytes; attaching/reading needs no json/storable fallback; ref-store still croaks | ⏳ |
| V5 | Regression: json/storable scalar, hash, array paths unchanged when `raw` not used | `prove -lj4 t/` | full suite green; no behavior change for existing serializers | ⏳ |
| V6 | `t/94-raw-serializer.t` (parallel-safe, `unique_glue` from t/IPCShareableTest.pm): pre-serialize a deep structure, store via scalar tie, fetch raw, user `decode_json`, deep-compare; assert exactly ONE segment created (`seg_count` delta == 1); locked + unlocked FETCH; cross-process attach; payload edge cases (empty, whitespace, literal `IPC::Shareable` tag, `\x1e`, NUL, UTF-8/wide, near-`size`, over-`size` → croak) | `prove -lv t/94-raw-serializer.t` | all subtests pass | ⏳ |
| V7 | Docs: POD `=head2 serializer` (`:2526`) + README `## serializer` (`:303`) + SERIALIZATION section document `raw` mode, the symmetric you-encode/you-decode contract, single-segment tradeoffs (sizing, whole-blob replace, no nested locking), retained 14-byte tag; add Changes entry at the BOTTOM of the `1.18 UNREL` section | `perldoc -T lib/IPC/Shareable.pm \| grep -A3 -i raw`; visual diff of Changes/README | docs describe raw mode + tradeoffs; Changes entry is last in its section | ⏳ |
| V8 | json auto-sense **write**: add `detect_serialized` attribute (default `1`) to `%default_options` + `_parse_args` validation; add `_looks_pre_serialized` (policy B); thread `$knot` into `_encode_json` and, for a json SCALAR whose value matches, write `'IPC::Shareable' . "\x1e" . $$data` instead of the `{__sv__}` wrapper (keep size guard) | store `'{"a":1}'` via a plain json scalar tie; dump `seg->shmread` | bytes == `IPC::Shareable\x1e{"a":1}`; `'hello'` still stored as `{"__sv__":"hello"}` | ⏳ |
| V9 | json auto-sense **read** + backward compat: in `_decode_json`, after stripping the 14-byte tag, if byte 0 == `\x1e` strip it and return `\$rest` verbatim; else the existing `decode_json` / `__sv__` / `__ics__` path | round-trip a sentinel value; also read a legacy `{__sv__}` and an `{__ics__}` segment | sentinel value FETCHes byte-identical; legacy `__sv__`/`__ics__` segments still decode | ⏳ |
| V10 | `t/95-detect-serialized.t` (parallel-safe, `unique_glue`): auto-sense matrix — object/array/deep JSON strings → sentinel + identical round-trip; numbers, bools, `null`, plain strings, invalid-JSON-looking strings → normal `{__sv__}` path; flip-flop (wrapped → sentinel → wrapped); `detect_serialized=>0` restores exact legacy bytes; backward-compat reads of old segments | `prove -lv t/95-detect-serialized.t` | all subtests pass | ⏳ |
| V11 | `t/96-pre-serialized-validation.t` (parallel-safe): **param validation + misuse + refs**. Bad `serializer` croaks; `raw`+`var=>HASH/ARRAY` croaks; `detect_serialized` inert for storable. In **raw** mode every ref croaks clearly — blessed object, cref, glob, `qr//`, hashref/arrayref/scalarref, IPC::Shareable child. In **json auto-sense** mode object/cref behavior is **unchanged from today** (blessed → serialized via `-convert_blessed_universally`; cref → croaks). Payload hazards (literal tag, `\x1e`, NUL, `__sv__`/`child_key_hex` text, UTF-8, over-`size`) | `prove -lv t/96-pre-serialized-validation.t` | all subtests pass | ⏳ |
| V12 | Docs for auto-sense: POD + README document `detect_serialized` (default on), the `\x1e` sentinel format, the symmetric contract, and the **cross-version caveat** (sentinel segments unreadable by pre-feature IPC::Shareable; new code still reads old segments). Changes entry at BOTTOM of `1.18 UNREL`. Confirm full suite | `prove -lj4 t/`; `perldoc -T lib/IPC/Shareable.pm \| grep -i detect_serialized` | docs updated; suite green; Changes entry last in section | ⏳ |

## Discovery Tracking

_None yet._

## Backlog

B1: _(promoted to V8–V12 — slot retired, not reused)_

B2: Optional read-side convenience flag (e.g. `decode => sub {...}`) to auto-decode on FETCH. Default-off; documented footgun (scalar tie returning a structure). Likely "NOT doing" — captured here only so the idea isn't re-litigated.

B3: Benchmark raw-scalar-single-segment vs. native fan-out tie on a deep structure (segment count, semaphore count, store/fetch wall-time) for the README/benchmarks dir.

## Explicitly NOT doing

- **Auto-decode on read by default** — breaks scalar-tie semantics, re-incurs the decode cost we're eliminating, and returns a detached non-shared ref. Read is a symmetric bypass (Design decision #1).
- **Partial/nested updates or per-child locking in raw mode** — raw is whole-blob replace by design; callers wanting sub-structure locking should use a normal hash/array tie.
- **Dropping the 14-byte `IPC::Shareable` tag in raw mode** — would make segments invisible to `shm_segments()` / `clean_up_testing` and orphan them.
- **In-band serializer self-description for `raw`** — both ends agree via the `serializer` attribute, consistent with existing json/storable expectations. The `\x1e` sentinel lives only on the json auto-sense path (V8/V9); `raw` mode stays sentinel-free.
