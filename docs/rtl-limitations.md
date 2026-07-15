# FPC -Tgba runtime limitations and patches

FPC's `-Tgba` cross target ships a thin RTL, and parts of it were broken in
ways that only surface once you exercise heap allocation or numeric string
formatting on real hardware timing. This page tracks the confirmed bugs,
what this repo's patches fix, how to apply them, and the one bug that is
still unresolved.

## Confirmed bug: Format, IntToStr, and Str are unusable

`Format()`, `IntToStr()`, and `Str()` consistently crash or produce garbage
on `-Tgba` builds. Observed symptoms:

- `IntToStr(42)` followed by any use of its result wedges the program at a
  fixed program counter, with no output produced.
- `Str(42, ss)` into a shortstring variable jumps the CPU to an unrelated,
  unmapped address, crashing outright.
- Even a plain character copy into a previously `SetLength`'d ansistring
  can come out truncated, as if the ansistring's length header is getting
  corrupted somewhere in these code paths.

The heap itself is demonstrably functional once the three patches below are
applied: `SetLength` allocates real, distinct memory, writes to it survive,
and plain static-string assignment to ansistring variables works cleanly.
The failure is specific to the numeric-formatting code paths that `Format`,
`IntToStr`, and `Str` all route through. The suspected root cause is either
an ansistring header or refcount handling bug specific to the codegen path
FPC uses for this target, or a thumb-interworking mismatch against the
libc this target links; it has not been root-caused or fixed.

**Workaround**: use `DbgLogStr` (or any string-consuming call) with static
string literals only; never route dynamic content through `Format`,
`IntToStr`, or `Str` on this target. For content that has to vary at
runtime, build a shortstring by hand with direct character assignment
(`s[1] := 'a'; s[2] := 'b';` followed by a single `SetLength`), or
pre-build a small set of static string variants and select between them by
index instead of formatting a number into text. See
[Debug logging](debugging.md) for how this interacts with the DbgLog
convention specifically: `DbgLog` and `DbgLogLevel` call `Format`
internally and are unusable for this reason, while `DbgLogStr` does not
call `Format` and is safe.

## Patches shipped in tools/fpc-patches/

Three separate bugs in FPC's GBA RTL source, each with its own patch file.
All three are fixed; none of them touch the Format/IntToStr/Str bug above,
which remains open.

### prt0-libc-init-array.patch

**Symptom**: any feature that touches dynamic memory (heap allocation,
ansistring concatenation, dynamic arrays, class instantiation) corrupts
memory in ways that surface later and far from the actual cause: garbage
reads, unexplained wedges, or crashes with no obvious connection to the
code that triggered them.

**Cause**: FPC's GBA startup code (`prt0.as`) jumps directly from its own
stack setup to the program's `main` entry point. It never calls
`__libc_init_array`, the routine that initializes newlib's heap
reentrancy structures and runs any registered static constructors from the
linked libc/libgba. Modern devkitARM's own crt0 startup calls this routine
before `main()`; FPC's `prt0.as` predates that convention and never picked
it up, so newlib's heap state is left uninitialized and the first
allocation walks through unset internal pointers.

**Fix**: the patch inserts a call to `__libc_init_array` immediately before
the jump to `main`, matching what devkitARM's own startup code does.

### sysheap-bump-allocator.patch

**Symptom**: the first heap allocation in a program works; every
allocation after it silently corrupts, with classic symptoms like two
unrelated variables appearing to alias each other, or one `SetLength`'d
string overwriting an earlier one.

**Cause**: `sysheap.inc`'s `SysOSAlloc`, the function FPC's heap manager
calls whenever it needs a fresh block of OS memory, ignores its `size`
argument entirely and always returns the same fixed pointer: the start of
the EWRAM heap region. The first call happens to work because it hands out
a genuinely free chunk. Every call after that hands out the exact same
address again, so the new allocation silently overwrites whatever the
previous one was using.

**Fix**: replaces `SysOSAlloc` with a linear bump allocator that tracks a
running pointer across the `__eheap_start .. __eheap_end` region the
linker reserves, advances it by each requested size (rounded up to 4-byte
alignment), and returns `nil` once the region is exhausted.

### system-pp-linklibs.patch

**Symptom**: link failures referencing `__libc_init_array` or heap glue
symbols once the prt0 patch above is in place and actually calls into
libc; before that, only some builds succeed, depending on whether the
installed devkitARM version happens to already bundle those symbols into
`libsysbase`.

**Cause**: `system.pp` links only `{$linklib sysbase}`. Older devkitARM
releases rolled the relevant newlib symbols directly into `libsysbase`, so
that one linklib was sufficient. Modern devkitARM splits them across a
separate `libc.a` (newlib proper: `__libc_init_array`, heap, libgloss
glue) and `libgcc.a` (64-bit division and modulo helpers that FPC's code
generator emits calls to, since the ARM7TDMI has no hardware divide
instruction).

**Fix**: adds `{$linklib c}`, `{$linklib gba}`, and `{$linklib gcc}`
alongside the existing `{$linklib sysbase}`, matching the library set a
modern devkitARM program links against.

## Applying the patches

`tools\fpc-patches\apply.ps1` applies all three during toolchain install.
It targets the fpcupdeluxe-managed FPC source tree (`fpcsrc\rtl\gba\`
under the fpcupdeluxe installation root, `C:\fpcupdeluxe\` by default on
Windows). Each patch is idempotent: `apply.ps1` guards every edit with a
marker string already present in the target file, so re-running it after a
tree has already been patched is a no-op rather than a double-apply.

Run it after installing FPC's GBA RTL source and before building the RTL
itself. `apply.ps1` edits the RTL source in place; the subsequent RTL build
step compiles the patched tree, and the ordinary `-Tgba` build flow then
links against the result.

## Licensing

FPC's RTL is distributed under a modified LGPL (see FPC's `COPYING.FPC`)
that permits linking without imposing LGPL's obligations on the linking
program, provided modified RTL source is made available to users of the
resulting binaries. The patch files under `tools\fpc-patches\` carry the
modified sections in patch form against FPC's public GBA RTL source, which
satisfies that obligation: applying them to the corresponding upstream FPC
release reconstructs exactly what this toolchain builds against.
