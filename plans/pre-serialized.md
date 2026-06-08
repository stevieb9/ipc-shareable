# Plan: Pre-serialized single-segment scalar storage

> **NEXT ACTION:** ✅ DONE — V1–V13 complete (feature + tests + docs + benchmark). B2 declined. Serial suite 1316 green.
> **LAST SESSION:** V13 ✅ — benchmarks/verbatim_vs_fanout.pl: 13× fewer segments, ~160× faster store, ~140× faster read vs fan-out
> **ARCHIVE:** See pre-serialized-archive.md for completed V1-V13

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

### Design decision #3 — verbatim scalar storage is AUTOMATIC and invisible (no public `raw`)

**Pivot (supersedes the V1–V6 public `serializer => 'raw'`):** the user decided NOT to
expose `raw` as a user-facing option ("users need not know about it"). A tied scalar should
just store arbitrary data — plain in, plain out — with **no new API surface**. So the
verbatim codec stays, but it is never user-selected; it triggers automatically.

**The rule (per-value, decided in `_encode`/`_decode`, serializer-agnostic):**
for a **SCALAR** tie, if the stored value is `defined && ! ref` → store it **verbatim**;
otherwise use the configured serializer's normal path:
- **ref** → fans out into child segment(s) (json) / freezes (storable), unchanged;
- **undef** → normal path (`{"__sv__":null}` / storable), so `undef` stays `undef`;
- **hash/array ties** → entirely unchanged.

The only check is `ref()`. No `detect_serialized` attribute, no JSON sniff, no
`decode_json` validation. Numbers come back as their string form (accepted: "plain in,
plain out"; Perl coerces). Strings round-trip byte-identical — the actual goal.

**In-band marker (still required):** a verbatim segment must be distinguishable from a
normal `{…}`/storable body so the *reader* knows not to deserialize. Layout:
`'IPC::Shareable'` (14-byte tag) + `\x1e` (1-byte sentinel) + verbatim bytes. Normal json
bodies always start `{`/`[`; storable has its own header; neither is `\x1e`. The sentinel
peek sits at the top of `_decode` (before serializer dispatch) so json- and
storable-configured readers both recognize a verbatim segment.

**Docs (all the user ever sees):** "A tied scalar can store arbitrary data. If you encode
it, you decode it; if you send in plain data, you get back plain data." No mention of
`raw`, sentinels, or the internal mechanism — keeps the normal usage uncluttered.

**Compatibility:** new code reads old `{__sv__}` / storable scalar segments fine; a verbatim
segment is unreadable by a pre-feature IPC::Shareable (it'd choke on `\x1e`) — new release only.

### Edge cases / constraints

- **Refs in a scalar tie:** NOT verbatim — a ref takes the normal serializer path (json
  `__ics__` fan-out / storable freeze), exactly as today. No croak (that was the abandoned
  public-`raw` behavior). The verbatim branch is gated on `! ref`.
- **Segment sizing:** a verbatim blob lives in one segment, so the caller sets `size` large
  enough. The existing `length > $seg->size` croak (`:1286`/`:1482`) is the guard.
- **NUL bytes:** verbatim decode reads via `shmread` and strips only trailing NUL padding,
  *not* at the first NUL (`SharedMem::data()` truncates at first NUL, `:181`). JSON/text is
  NUL-free; internal NULs are preserved (verified in V3/V6).
- **`_decode` ordering:** the `\x1e` sentinel peek runs *before* serializer dispatch so both
  json- and storable-configured readers recognize a verbatim segment; `_tie` post-attach must
  route through `_decode` (not a bare `_thaw`) so storable scalars catch verbatim segments too.
- **Introspection:** `shm_segments()` child-key regex won't false-match (no children) unless
  a verbatim payload literally contains `"child_key_hex":"…"` — a pre-existing theoretical
  class of issue, not a regression; note it.

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
_All V tasks (V1–V13) complete — see pre-serialized-archive.md._

## Discovery Tracking

_None yet._

## Backlog

B1: _(promoted to V8–V12 — slot retired, not reused)_

B2: _(decided against — see Explicitly NOT doing — slot retired, not reused)_

B3: _(promoted to V13 — slot retired, not reused)_

## Explicitly NOT doing

- **Public `serializer => 'raw'` option** — verbatim storage is internal and automatic only (SCALAR tie + `defined && ! ref`); users never select it. Keeps the normal API surface unchanged (Design decision #3). The codec helpers exist; the *option* does not.
- **Auto-decode on read by default** — breaks scalar-tie semantics, re-incurs the decode cost we're eliminating, and returns a detached non-shared ref. Read hands back the stored bytes; the user decodes (Design decision #1).
- **Auto-decode-on-read convenience flag** (was B2) — e.g. a `decode => sub {…}` hook that deserializes on FETCH. Same footgun as above (detached non-shared structure, re-incurred cost); the caller decoding explicitly is clearer. Decided against.
- **Preserving number type through a verbatim scalar** — a stored number returns as its string form (still `==`). Accepted per "plain in, plain out"; not worth a fragile SvIOK/SvPOK sniff.
- **Dropping the 14-byte `IPC::Shareable` tag for verbatim segments** — would make segments invisible to `shm_segments()` / `clean_up_testing` and orphan them. Tag stays; the `\x1e` sentinel follows it.
