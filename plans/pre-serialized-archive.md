# Archive — completed V tasks and resolved fixes

## Archived V Tasks

- V1: Recognize `serializer => 'raw'`; validate serializer (json/storable/raw) in `_parse_args` — ✅ 2026-06-06 attempt 1: PASS
- V2: `_encode` raw branch (`_encode_raw`) — verbatim tag+payload write, size guard, ref croak (STORE guard pulled forward from V4) — ✅ 2026-06-06 attempt 1: PASS
- V3: `_decode` raw branch (`_decode_raw`) — verbatim read, strips only trailing NUL padding, untagged → undef, internal NULs preserved — ✅ 2026-06-06 attempt 1: PASS

## Archived Fixes

_None yet._
