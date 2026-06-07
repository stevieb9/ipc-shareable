# Archive — completed V tasks and resolved fixes

## Archived V Tasks

- V1: Recognize `serializer => 'raw'`; validate serializer (json/storable/raw) in `_parse_args` — ✅ 2026-06-06 attempt 1: PASS
- V2: `_encode` raw branch (`_encode_raw`) — verbatim tag+payload write, size guard, ref croak (STORE guard pulled forward from V4) — ✅ 2026-06-06 attempt 1: PASS
- V3: `_decode` raw branch (`_decode_raw`) — verbatim read, strips only trailing NUL padding, untagged → undef, internal NULs preserved — ✅ 2026-06-06 attempt 1: PASS
- V4: `_tie` raw post-attach uses `_decode` (cross-process attach works); enforce raw = SCALAR-only croak at tie time — ✅ 2026-06-06 attempt 1: PASS
- V5: Full-suite regression with raw implemented — ✅ 2026-06-06 attempt 1: PASS (Files=60, Tests=1255)
- V6: `t/94-raw-serializer.t` — round-trip, single-segment vs fan-out, strings/ints/floats, edge payloads (empty/ws/tag/\x1e/NUL/UTF-8/size), locked+unlocked, cross-process — ✅ 2026-06-06 attempt 1: PASS (31 tests)
- V7: Un-expose `serializer => 'raw'` — removed public option + `_encode`/`_decode` raw branches + STORE ref-guard + `_tie` SCALAR-only croak/post-attach; deleted obsolete t/94-raw-serializer.t; codec helpers retained for V8/V9 — ✅ 2026-06-06 attempt 1: PASS (raw rejected; suite 1258 green)
- V8: Automatic verbatim **encode** — `_encode` writes `tag.\x1e.bytes` for SCALAR + `defined && ! ref` (serializer-agnostic `_encode_verbatim`); refs fan out, undef → `{"__sv__":null}` — ✅ 2026-06-07 attempt 1: PASS (encode bytes verified; suite intentionally red until V9 decode)
- V9: Automatic verbatim **decode** — `_decode_verbatim` sentinel peek at top of `_decode` (scalar-gated); `_tie` storable post-attach routed through `_decode`. Round-trip verified (plain/number/undef/ref/flip-flop, json+storable); storable freeze leads with 0x04 (never `\x1e`) so no collision; suite green (1257) — ✅ 2026-06-07 attempt 1: PASS
- V10: `t/94-scalar-verbatim.t` (37 tests) — segment layout (tag+\x1e, no __sv__), deep-structure single-segment + user decode, fan-out contrast, strings/ints/floats, undef preserved, refs fan out, flip-flop string↔ref w/ child cleanup, locked/unlocked, payload hazards (tag/\x1e/NUL/UTF-8), size guard, cross-process — ✅ 2026-06-07 attempt 1: PASS (serial suite 1296 green, t/99 leak check passes; `prove -j4` w/o HARNESS_OPTIONS races t/99 — use serial or HARNESS_OPTIONS=j4)
- V11: `t/95-scalar-verbatim-edge.t` (21 tests) — legacy `{__sv__}` read, literal `__sv__` string verbatim (sentinel protection), legacy Storable-frozen scalar → json fallback warns/switches, storable scalar plain=verbatim/ref=freeze, aggregate ties unaffected, serializer validation (raw/bogus/none rejected) — ✅ 2026-06-07 attempt 1: PASS (serial suite 1317 green)

## Archived Fixes

- Fix 1 (from V9): t/67 block 1 and t/60 tests 12-13 asserted the old storable-scalar behavior (json fallback warning / `_thaw` croak driven through a scalar). Plain storable scalars now store verbatim and bypass freeze/thaw, so both were updated — t/67 block 1 asserts cross-serializer verbatim read with no fallback; t/60 exercises `_thaw` via a hash tie. Legacy frozen-scalar fallback coverage moved to V11.
