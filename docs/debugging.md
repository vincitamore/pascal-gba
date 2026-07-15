# Debug logging

Cart code has no console and no debugger. DbgLog is a one-way narration
channel: the game writes a string into a fixed EWRAM address, the emulator
polls that address once per frame and prints or records whatever it finds.
It exists so a ROM that crashes, hangs, or misbehaves leaves a trail you can
read after the fact, without wiring up a real hardware debugger.

## Wire format

The convention is a fixed 128-byte region at the tail of the first EWRAM
mirror:

```
$0203FF80 .. $0203FFFE   127-byte string buffer, null-terminated
$0203FFFF                ready byte
```

The ready byte means:

- `0`   idle, no message pending
- `!=0` message ready; the value is the log level (1 = info, 2 = warn,
  3 = error by convention)

Game code writes the string content first, then the ready byte last. Once the
ready byte is non-zero the emulator may consume the message at any frame
boundary; writing the ready byte before the content is fully written would
race the poll. The emulator's poll runs once per emulated frame: it checks
the ready byte, and if non-zero, reads the buffer up to the first null byte
(capped at 127 characters), records the message, then clears the ready byte
back to zero via a normal memory write. Non-printable bytes are mapped to
`?` on the way out so a corrupted capture doesn't garble the log stream.

Every DbgLogStr call zero-fills the full 127-byte buffer before writing the
new content and its null terminator. Without this, a short message written
after a longer one leaves stale bytes sitting past the new null terminator.
The emulator's own read stops at the first null, so this is invisible in
the normal capture path, but any raw inspection of the buffer (a memory
dump, a future capture path that reads fixed-width instead of
null-terminated) would pick up the stale tail and mistake it for content.
The zero-fill costs roughly 127 extra byte writes per call, which is
irrelevant on a path that only fires when you're actively narrating.

## Why EWRAM, not IWRAM

The buffer lives in EWRAM's tail rather than IWRAM, and that placement is
load-bearing, not arbitrary.

An earlier version of this convention put the buffer in IWRAM at
`$03007E80..$03007EFE`, on the reasoning that it sat below the BIOS-managed
IRQ stack and was therefore "out of the way" of anything the cart was
doing. That's wrong for the region that actually matters. Per the GBA's
documented post-reset register state (GBATEK), the BIOS sets:

```
SP_usr = $03007F00
SP_irq = $03007FA0
SP_svc = $03007FE0
```

`SP_usr` is the cart's user/system-mode stack pointer, and the stack grows
down from there. Any region you reserve just below `$03007F00` sits inside
the address range the user stack will occupy as soon as the cart makes a
nested call. A function two or three calls deep has its saved frame pointer,
link register, and return address living in exactly the bytes a naive
"scratch region below the stack" comment assumes are free. Writing to the
upper part of that region overwrites a caller's saved registers. On return,
the CPU resumes at garbage, and you get an unmapped-memory-access flood
within a handful of frames with no obvious connection to the debug helper
that caused it.

The buffer now lives at the tail of EWRAM (`$0203FF80..$0203FFFF`) instead.
EWRAM and IWRAM are different physical regions, so no user-stack overlap is
possible there regardless of how deep the cart's call chain gets at the
moment of the write. The trade-off is access speed: EWRAM is roughly 3-cycle
access versus IWRAM's 1-cycle. On a 16.78 MHz ARM7TDMI core that's on the
order of 20 microseconds versus 5 microseconds per DbgLogStr call, which is
negligible for a path that exists only to narrate, not to run every frame
in the hot render loop.

## Footgun 1: multiple calls per frame overwrite each other

The emulator only samples the ready byte once per emulated frame. If cart
code calls DbgLogStr twice before that poll runs, the second call
overwrites the first call's content in the buffer, and the poll only ever
sees the last write. The lost message doesn't produce an error; the trace
just looks slightly incomplete, which is easy to miss when you're not
specifically counting messages.

The discipline: call `DbgLogWaitConsumed` between any two DbgLogStr calls
that fire on the same code path in quick succession. It busy-waits on the
ready byte returning to zero, which happens on the next frame poll, so the
worst case is one frame of latency before the next write is safe to issue.
For per-frame narration where at most one message can fire per game frame,
no wait is needed, since there's nothing else in flight to overwrite.

One hard caveat: the wait is unbounded, and only this emulator's poll ever
clears the ready byte. On real hardware or under any other emulator the
byte stays set forever and `DbgLogWaitConsumed` spins the cart into a
permanent hang. A cart that must also run off-emulator calls
`DbgLogWaitConsumedBounded(maxFrames)` instead — same unit, same
consumption wait, but it gives up after maxFrames vblank edges: full
narration under the emulator, a few wasted frames anywhere else.
`test/device_smoke.pp` uses it throughout.

## Footgun 2: register clobber across the call

`DbgLogStr` and `DbgLogWaitConsumed` are ordinary Pascal procedure calls.
Under the ARM calling convention, a callee is free to trash the
caller-saved registers R0-R3; nothing obligates it to preserve them. If
FPC's optimizer allocated a local variable into one of those registers, and
the caller reads that local after the call returns, it gets whatever value
the callee left behind rather than the value assigned before the call.

The symptom looks unrelated to logging at first: a local holding, say, a
keypad bitmask reads back a bit pattern that doesn't match the actual
hardware register, immediately after a DbgLogStr/DbgLogWaitConsumed pair.
`DbgLogWaitConsumed` in particular is a tight polling loop that a compiler
is likely to emit with the address in one register and the read value in
another, both of which are caller-saved.

The fix is to promote any local whose value must survive a DbgLogStr or
DbgLogWaitConsumed call to a unit-level variable instead of a function
local. Globals live in IWRAM (in the BSS or DATA section, depending on
whether they're initialized), never in a register, so a procedure call
cannot clobber them. Locals that are only written after the call, and never
read again afterward, are unaffected and can stay local.

```pascal
{ Before: keys is a function local; a DbgLogStr/WaitConsumed pair
  between the read and the later use can clobber it. }
procedure StepInput;
var
  keys, pressed: Word;
begin
  keys := ReadKeys;
  ...
  DbgLogStr('selected');
  DbgLogWaitConsumed;
  { keys may read back garbage here }
end;

{ After: promote survivors to unit-level vars, which live in IWRAM
  and cannot be touched by a procedure call. }
var
  inputKeys, inputPressed: Word;

procedure StepInput;
begin
  inputKeys := ReadKeys;
  ...
  DbgLogStr('selected');
  DbgLogWaitConsumed;
  { inputKeys is unaffected }
end;
```

## Headless capture: --dbglog-out

The runner binary, `bin\gbarun.exe`, accepts `--dbglog-out PATH`. At
shutdown it writes the emulator's DbgLog ring buffer (the most recent
captured messages, oldest first) to PATH: each line carries the game
frame, the log level, and the text. The header also reports how many
entries are in the ring versus the total ever captured, so you can tell
whether messages were dropped past the ring's capacity.

```powershell
.\bin\gbarun.exe --rom test\dbg_smoke.gba --headless --frames 600 --dbglog-out bin\dbg_smoke.dbglog.txt
```

This is the workflow to reach for when a live trace scrolled past or got
truncated mid-run, since the ring buffer preserves the tail of the
narration independent of whatever you happened to be watching on stdout at
the time. It combines cleanly with `--replay` and `--screenshot` in a
single invocation, so one run can capture scripted input, a framebuffer
image, and the debug narration together.

## Format()-based DbgLog paths are unusable on -Tgba

`DbgLog` and `DbgLogLevel` call `Format` internally to build their string
before handing it to the same wire format described above. `Format` (and
the numeric-formatting paths it depends on) is broken on FPC's `-Tgba`
cross target; see [FPC -Tgba runtime limitations and patches](rtl-limitations.md)
for the specifics. Until that's fixed, only `DbgLogStr` with static string
literals is safe to call. Build dynamic content by hand: pack a
shortstring's characters directly, or pre-build a small set of static
string variants and pick between them by index at runtime.
