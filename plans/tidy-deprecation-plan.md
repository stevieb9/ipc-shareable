# Plan: Decommission the `tidy` attribute

## Background

The `tidy` attribute (default: 1) controlled whether `_magic_tie()` called
`_reset_segment()` to remove an old tied child segment when a hash/array
element was overwritten with a new reference value.  With `tidy => 0`, the
old child was orphaned (leaked); with `tidy => 1`, it was cleaned up.

## Why `tidy` is now dead code

The STORE child-segment leak fix (2026-05-21) added `_remove_child()` calls
at the top of every STORE branch, before `_magic_tie()` runs.  This means the
old child is already removed from the kernel by the time `_reset_segment()`
(gated by `tidy`) executes.  The full call chain is:

```
STORE
  ├─ _remove_child($old_value)     # NEW: removes old child segment+semaphore
  └─ _magic_tie($new_value)
       └─ _reset_segment($parent)  # OLD: tries to remove old child again
```

The only effect of `tidy => 1` now is a spurious warning:

    Couldn't remove shm segment <id>: Invalid argument
    Couldn't remove semaphore set <id>: Invalid argument

This is `_reset_segment()` calling `$child->remove` on a segment that
`_remove_child()` already removed.

## Evidence

`t/46-nested_segs_tidy_deprecate.t` proves:

1. **Segment counts are identical** with `tidy => 0` and `tidy => 1` across
   five operations (initial creation, first nested store, flat overwrite,
   second flat overwrite, deep nested overwrite).  Both array and hash tests
   pass.

2. **Data is identical** with `tidy => 0` and `tidy => 1`.  The deep-cloned
   data matches the expected test data for both tidy values.

3. **The only observable difference** is the stderr warning noise from the
   redundant `_reset_segment()` removal in the `tidy => 1` path.

## Proposed changes

### Phase 1: Soft deprecation (next dev release)

1. **Add a deprecation warning** in `_parse_args` when `tidy` is explicitly
   set, emitted once per process:
   ```perl
   if (exists $opts{tidy}) {
       carp "IPC::Shareable: 'tidy' attribute is deprecated and has no effect. "
          . "Child segments are now always cleaned up on overwrite.";
   }
   ```

2. **Remove `_reset_segment()` calls** from `_magic_tie()` (lines 1592,
   1601).  This stops the spurious double-removal warnings immediately,
   even before the attribute is fully removed.

3. **Remove `_reset_segment()` sub** entirely (lines 1755-1783).  It is
   not called from anywhere else.

4. **Update POD** to mark `tidy` as deprecated, explaining that child
   cleanup on STORE overwrite is now automatic.

### Phase 2: Hard removal (next stable release, after soft deprecation has been in a CPAN release for ≥1 cycle)

1. **Remove `tidy` from `%DEFAULT_ARGS`** (line 147).

2. **Remove the deprecation warning** from `_parse_args`.

3. **Remove `tidy` from POD** entirely.

4. **Remove `t/44-nested_segs_tidy.t`** — it now tests the exact same
   behavior as `t/45-nested_segs_untidy.t` (both pass identically).

5. **Rename `t/46-nested_segs_tidy_deprecate.t`** to a permanent test
   name (e.g., `t/44-nested_segs_overwrite.t`) that verifies child
   cleanup on overwrite regardless of tidy.

6. **Update `t/14-attributes.t`** to remove the `tidy` attribute check.

7. **Add Changes entry** for the removal.

## Files affected

| File | Phase 1 | Phase 2 |
|------|---------|---------|
| `lib/IPC/Shareable.pm` | Warn in `_parse_args`; remove `_reset_segment` calls + sub | Remove `tidy` default; remove warning; remove POD |
| `t/44-nested_segs_tidy.t` | — | Delete |
| `t/45-nested_segs_untidy.t` | — | Unchanged (already tests no-tidy behavior) |
| `t/46-nested_segs_tidy_deprecate.t` | — | Rename to `t/44-nested_segs_overwrite.t` |
| `t/14-attributes.t` | — | Remove `tidy` check |
| `Changes` | Entry | Entry |

## Risk assessment

- **Risk**: Low. `_reset_segment` has been a no-op since the STORE fix.
  Removing it changes no observable behavior (other than eliminating
  spurious warnings).
- **Backward compatibility**: Anyone explicitly setting `tidy => 0`
  expecting the old leak behavior will now get the same non-leaking
  behavior.  This is strictly an improvement — the old behavior was a
  bug (segments leaked).
- **CPAN downstream**: No known modules depend on `tidy`.  A grep of
  MetaCPAN shows zero uses of `tidy` with `IPC::Shareable` outside of
  this distribution's test suite.
