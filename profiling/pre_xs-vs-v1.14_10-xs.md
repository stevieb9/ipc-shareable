# Profile Comparison: v1.14_10 vs v1.14_10-2 (XS build)

Both profiles run with the XS `.bundle` loaded (`_is_child_xs` xsub active in both).

## Overall

| Metric | v1.14_10 | v1.14_10-2 | Delta |
|--------|----------|------------|-------|
| Total time | **174ms** | **643ms** | +469ms |
| DynaLoader (XS bootstrap) | — | 500ms (77.7%) | one-time load cost |
| Shareable.pm time | 113ms (65%) | 79.8ms (12.4%) | **-33ms (-29%)** |
| SharedMem.pm time | 19.8ms (11.4%) | 17.9ms (2.8%) | -1.9ms (-10%) |
| Statements | 90,131 | 91,016 | +885 |

The 643ms total in v1.14_10-2 is inflated by 500ms of DynaLoader bootstrap
overhead from XS `.bundle` loading — a one-time startup cost that amortizes over
process lifetime. The prior v1.14_10 profile was run with `-Ilib` (not
`-Mblib`), so the `.bundle` was already resolved via a different load path that
didn't register as DynaLoader time. Ignoring the DynaLoader line-item,
Shareable.pm + SharedMem.pm together dropped from ~133ms to ~98ms, a 26%
reduction.

Shareable.pm alone accounts for nearly all of the gain (-33ms), attributable
to the three cumulative optimizations: seg_map ipcs dedup, backtick-to-pipe-open
replacement, and the _lock_children iterative rewrite.

## `_lock_children` — before vs after

| Metric | v1.14_10 (recursive) | v1.14_10-2 (iterative) |
|--------|----------------------|------------------------|
| Total calls | 53 (20 ext + 33 recursive) | **20 (all external)** |
| Exclusive time | 414µs | 464µs |
| Inclusive time | 1.69ms | **1.53ms (-9.5%)** |
| Avg per lock() call | 85µs | **77µs (-9.4%)** |
| Max recursion depth | 7 | **0 (none)** |
| Recursive overhead | 3.92ms | **eliminated** |

The iterative rewrite eliminated all 33 recursive self-calls and the
max-depth-7 call stack. The inclusive cost from the caller's perspective
dropped from 1.69ms to 1.53ms. As predicted in the plan, the gain is modest
(~9.5% on this function, ~0.16ms absolute) because `semop` and
`shmread`/deserialize still dominate the per-child cost.

## `_is_child` — XS vs fallback confirmation

| Metric | v1.14_10 | v1.14_10-2 |
|--------|----------|------------|
| `_is_child_xs` calls | 272 | 271 |
| `_is_child_xs` avg | 232ns | 188ns |

Both profiles ran with the XS path active for `_is_child`.

The profile data (both old and new) is at `profiling/v1.14_10/` and
`profiling/v1.14_10-2/`, with NYTProf HTML reports in their `nytprof/`
subdirectories.
