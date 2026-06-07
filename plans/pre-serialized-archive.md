# Archive — completed V tasks and resolved fixes

## Archived V Tasks

- V1: Recognize `serializer => 'raw'`; validate serializer (json/storable/raw) in `_parse_args` — ✅ 2026-06-06 attempt 1: PASS
- V2: `_encode` raw branch (`_encode_raw`) — verbatim tag+payload write, size guard, ref croak (STORE guard pulled forward from V4) — ✅ 2026-06-06 attempt 1: PASS
- V3: `_decode` raw branch (`_decode_raw`) — verbatim read, strips only trailing NUL padding, untagged → undef, internal NULs preserved — ✅ 2026-06-06 attempt 1: PASS
- V4: `_tie` raw post-attach uses `_decode` (cross-process attach works); enforce raw = SCALAR-only croak at tie time — ✅ 2026-06-06 attempt 1: PASS
- V5: Full-suite regression with raw implemented — ✅ 2026-06-06 attempt 1: PASS (Files=60, Tests=1255)
- V6: `t/94-raw-serializer.t` — round-trip, single-segment vs fan-out, strings/ints/floats, edge payloads (empty/ws/tag/\x1e/NUL/UTF-8/size), locked+unlocked, cross-process — ✅ 2026-06-06 attempt 1: PASS (31 tests)
- V7: Un-expose `serializer => 'raw'` — removed public option + `_encode`/`_decode` raw branches + STORE ref-guard + `_tie` SCALAR-only croak/post-attach; deleted obsolete t/94-raw-serializer.t; codec helpers retained for V8/V9 — ✅ 2026-06-06 attempt 1: PASS (raw rejected; suite 1258 green)

## Archived Fixes

_None yet._
