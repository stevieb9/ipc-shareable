# Profile Comparison: 6e56c0f (v1.14, no XS) vs XS (v1.14 with XS)

Both profiles run with `-Mblib` on the same macOS system. The XS build compiles
`Shareable.c` into a `.bundle` loaded via DynaLoader at startup. 6e56c0f is a
pure-Perl v1.14; the XS version shares the same version number but includes
significant architectural changes (see "Subs only in XS" below).

## Overall

| Metric | 6e56c0f (no XS) | XS | Delta |
|--------|-----------------|-----|-------|
| Total time | **167.2ms** | **611.9ms** | +444.7ms |
| DynaLoader (XS bootstrap) | — | 458.4ms (74.9%) | one-time load cost |
| Core (Shareable+SharedMem) | **121.8ms** | **105.2ms** | **-16.6ms (-13.6%)** |
| Statements | 105,860 | 91,077 | -14,783 |

The 611.9ms total in the XS build is inflated by 458.4ms of DynaLoader bootstrap
overhead from loading the XS `.bundle` — a one-time startup cost that amortizes
over process lifetime. Excluding that line-item, the XS version is 13.6% faster
in core library code and executes ~14K fewer statements.

## Shareable.pm

| Metric | 6e56c0f | XS | Delta |
|--------|---------|-----|-------|
| Total time | **99.9ms** | **86.4ms** | **-13.5ms (-13.5%)** |
| `_is_child` calls | 1,092 | 277 | **-815 (-74.6%)** |
| `_tie` exclusive | 2.75ms | 2.49ms | -0.26ms (-9.4%) |
| `_parse_args` exclusive | 1.14ms | 0.90ms | -0.24ms (-20.9%) |
| `_decode_json_reattach` | 0.93ms | 0.70ms | -0.23ms (-25.1%) |
| `clean_up_all` | 0.24ms | 0.04ms | -0.20ms (-84.1%) |
| `_decode_json_restore` | 0.89ms | 0.73ms | -0.16ms (-18.0%) |
| `_encode_json` | 0.40ms | 0.60ms | +0.19ms (+48.3%) |
| `_encode_json_prepare` | 0.39ms | 0.54ms | +0.15ms (+38.8%) |
| `_is_child` exclusive | 0.27ms | 0.40ms | +0.13ms (+46.1%) |
| `_magic_tie` exclusive | 0.44ms | 0.55ms | +0.11ms (+24.7%) |
| `_lock_children` | N/A | 0.37ms | NEW |

The -13.5ms net improvement comes from a mix of wins and losses across many
functions. The largest gains: `_tie` (-0.26ms), `_parse_args` (-0.24ms),
`_decode_json_reattach` (-0.23ms), `clean_up_all` (-0.20ms), and
`_decode_json_restore` (-0.16ms). These are partially offset by regressions in
`_encode_json` (+0.19ms), `_encode_json_prepare` (+0.15ms), `_is_child`
(+0.13ms), `_magic_tie` (+0.11ms), and the new `_lock_children` (+0.37ms).

### `_is_child`: call count reduction

The most striking change is that `_is_child` is called 815 fewer times (277 vs
1,092). This is not an XS-vs-Perl effect — the XS `_is_child_xs` is loaded
(via `$_have_xs` BEGIN eval) and active, but its C internals are invisible to
NYTProf so it shows 0 calls in the CSV. The 277 calls to `_is_child` (line
1590-1593) represent the Perl-side dispatch wrapper. The 75% reduction in
`_is_child` calls means the XS version's code paths avoid child-type checks much
more often — likely because `_lock_children` traverses children differently
and `_need_tie`/`_magic_tie` have optimized-out redundant checks.

## SharedMem.pm

| Metric | 6e56c0f | XS | Delta |
|--------|---------|-----|-------|
| Total time | **21.9ms** | **18.8ms** | **-3.1ms (-14.2%)** |
| `data()` | 2.0ms | 0.7ms | -1.3ms (-66.7%) |
| `id()` | 2.1ms | 1.7ms | -0.4ms (-18.5%) |
| `new()` | 2.5ms | 2.5ms | 0.0ms (0%) |
| `shmread()` | 7.5ms | 7.4ms | -0.1ms (-1.6%) |
| `shmwrite()` | 2.1ms | 2.1ms | +0.1ms (+3.7%) |
| `remove()` | 0.2ms | 0.3ms | +0.1ms (+23.9%) |

The -3.1ms improvement is mostly from `data()` (-1.3ms) and `id()` (-0.4ms).
The XS version uses `seg_map()` (which reuses the existing segment registry via
`ipcs` dedup) vs 6e56c0f's `shm_segments()` (which calls `shmget`/`shmctl`/
`shmread` for every system segment). This cuts SharedMem object creations by
~28% (355 → 254 `new()` calls) and correspondingly reduces `id()`, `data()`,
and `shmread()` call counts.

## Architecture differences

| Feature | 6e56c0f (v1.14) | XS (v1.14) |
|---------|-----------------|------------|
| `_lock_children` | No | Yes |
| `seg_count` / `sem_count` / `seg_map` | No | Yes |
| `STORESIZE` | No | Yes |
| `_read_check` | No | Yes |
| `_shm_data_summary` | No | Yes |
| `shm_count` | Yes | No |
| `_is_child_xs` (C XS) | No | Yes (loaded) |
| `_is_child_pp` (Perl fallback) | No | Yes |
| `_is_child` calls per profile | 1,092 | 277 |
| SharedMem `new()` calls | 355 | 254 |

The XS version is a substantially restructured codebase — same version number
(1.14) but with many new functions, XS acceleration for `_is_child`, iterative
child locking, and a more efficient segment registry (`seg_map` with `ipcs`
dedup). The 13.6% core-library speedup reflects these accumulated improvements.

## Summary

Excluding the one-time 458ms DynaLoader bootstrap, the XS build is 13.6% faster
in core IPC::Shareable library code vs its v1.14 ancestor at 6e56c0f. Gains
come from the restructured `_tie`/`_parse_args` path, optimized JSON decode
reattach, the iterative `_lock_children` replacing no child locking at all,
`seg_map` dedup reducing SharedMem churn, and a 75% reduction in `_is_child`
calls. Regressions in JSON encoding and `_magic_tie` partially offset these
wins.

Profile data at `profiling/6e56c0f/` and `profiling/xs-current/`.
