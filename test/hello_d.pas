program hello_d;
{
  Phase D capstone — a real ARM program drives the GBA through the
  full pipeline: CPU executes user code in EWRAM, PPU renders scanlines,
  IRQ controller fires V-blank, ARM IRQ handler runs in IRQ mode and
  updates the BG scroll registers, main CPU loop spins.

  The Pascal outer loop is now a per-scanline scheduler:
    for each scanline 0..227:
      run ~280 CPU instructions
      tick timers
      update input
      if scanline = 0..159:
        render the visible scanline
        if scanline = 159: fire V-blank IRQ + set DISPSTAT bit 0
      write VCOUNT register
    present framebuffer

  This is what "the GBA actually runs" looks like — the previous demo
  (hello_gba.exe) had Pascal driving the scroll registers; here the
  ARM code does it.
}

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, GbaTypes, Memory, ArmCore, Ppu, Display, Irq, Timers, Input;

const
  CYCLES_PER_SCANLINE = 280;     { rough approximation of real GBA's 1232 }
  SCANLINES_VISIBLE   = 160;
  SCANLINES_VBLANK    = 68;       { 160..227 }
  SCANLINES_TOTAL     = 228;
  WindowScale         = 3;

procedure SetupScene(mem: TGbaMemory);
var
  i, tileX, tileY: Integer;
  tileIdx: Integer;
  byteVal: TByte;
  halfVal: THalf;
  row: Integer;
  bgr: THalf;
  entry: THalf;
const
  Palette: array[0..4] of record r, g, b: Integer end = (
    (r:  2; g:  4; b:  8),     { backdrop: deep blue }
    (r: 28; g:  8; b: 12),     { red    }
    (r:  4; g: 26; b: 20),     { teal   }
    (r: 26; g: 20; b:  4),     { gold   }
    (r: 14; g:  8; b: 28)      { violet }
  );
begin
  for i := 0 to High(Palette) do
  begin
    bgr := THalf((Palette[i].b and $1F) shl 10)
         or THalf((Palette[i].g and $1F) shl 5)
         or THalf(Palette[i].r and $1F);
    mem.WriteHalf($05000000 + TWord(i) * 2, bgr);
  end;

  { Tiles 0..4 — each solid in palette index 0..4. Halfword writes
    (NOT bytes — VRAM duplicates byte writes across halfwords). }
  for tileIdx := 0 to 4 do
  begin
    byteVal := TByte((tileIdx and $F) or ((tileIdx and $F) shl 4));
    halfVal := THalf(byteVal) or (THalf(byteVal) shl 8);
    for row := 0 to 7 do
    begin
      mem.WriteHalf($06000000 + $4000 + TWord(tileIdx) * 32 + TWord(row) * 4 + 0, halfVal);
      mem.WriteHalf($06000000 + $4000 + TWord(tileIdx) * 32 + TWord(row) * 4 + 2, halfVal);
    end;
  end;

  { Tilemap at screen-block 0. Diamond + cross pattern. }
  for tileY := 0 to 31 do
    for tileX := 0 to 31 do
    begin
      if ((tileX mod 4) = 0) and ((tileY mod 4) = 0) then entry := $0001
      else if (((tileX + tileY) mod 6) = 0)           then entry := $0002
      else if (((tileX + tileY * 2) mod 9) = 0)       then entry := $0003
      else if (((tileX * 3 + tileY) mod 11) = 0)      then entry := $0004
      else                                                  entry := $0000;
      mem.WriteHalf($06000000 + TWord(tileY) * 32 * 2 + TWord(tileX) * 2, entry);
    end;

  { BG0CNT: char-base 1, screen-base 0, 4bpp, screen size 0. }
  mem.WriteHalf($04000008, $0004);
  { DISPCNT: mode 0, BG0 enabled. }
  mem.WriteHalf($04000000, $0100);
end;

procedure LoadArmProgram(mem: TGbaMemory);
{ Tiny ARM program loaded into EWRAM at $02000000.

  Main:
    - Sets up R1 = $04000000 (IO base, via MOV with rot-imm)
    - Sets up R3 = 1 in scroll-x
    - Zero ticks/vblanks counters in IWRAM
    - Pre-set IE/IME bits via direct STR (which writes 32-bit; fine
      because the high half of $04000200 is IF=0 which we want to be 0,
      and IME is at $208 with the high half being unused)
    - Switch to SYS mode with IRQs enabled
    - Main loop: just spin (the IRQ handler does the scroll updates)

  IRQ handler at $03000200:
    - Load BG0HOFS register value from IWRAM mirror at $03000110
    - Increment it
    - Write it back to BG0HOFS ($04000010, but reachable via STRH with
      offset $10 since R1 = $04000000)
    - Also write VOFS (offset $12) with a different rate
    - Ack IF: write 0 to IF via STR (zaps IE+IF together — but we re-set
      IE on every IRQ entry just before clearing IF)
       Simpler: use base-register pointing at IF directly via LDR literal
    - SUBS PC, LR, #4 }
const
  { Main program — exact layout planned for branch arithmetic. }
  Prog: array of TWord = (
    { $02000000 } $E3A01301,   { MOV R1, #$04000000   IO base
                                  (imm8=$01 ROR by 6 → bit 26 = $04000000.
                                   rot field=3, imm12=$301. Easy to confuse
                                   with $403 which is $03000000.) }
    { $02000004 } $E3A02000,   { MOV R2, #0 }
    { $02000008 } $E59F4040,   { LDR R4, [PC, #$40]   load IWRAM base = $03000000 → addr $50 }
    { $0200000C } $E5842100,   { STR R2, [R4, #$100]  ticks   := 0 }
    { $02000010 } $E5842104,   { STR R2, [R4, #$104]  vblanks := 0 }
    { $02000014 } $E5842110,   { STR R2, [R4, #$110]  hofs    := 0 }
    { $02000018 } $E5842114,   { STR R2, [R4, #$114]  vofs    := 0 }
    { $0200001C } $E3A03001,   { MOV R3, #1 }
    { $02000020 } $E1A00000,   { NOP (MOV R0, R0). DISPSTAT setup omitted — the
                                  Pascal scheduler fires V-blank IRQ directly,
                                  bypassing the DISPSTAT.bit3 hardware gate. My
                                  first attempt at STRH here had the wrong bit-7
                                  in the low byte, which the dispatcher decoded
                                  as BIC R3, R1, R0 LSR R2 and clobbered R3. The
                                  STRH 1011-signature in bits 7:4 is the GBA
                                  encoding trap par excellence. }
    { $02000024 } $E5813200,   { STR R3, [R1, #$200]  IE := 1 (V-blank).  Writes $00000001, IF=0 stays 0. }
    { $02000028 } $E5813208,   { STR R3, [R1, #$208]  IME := 1 }
    { $0200002C } $E3A0501F,   { MOV R5, #$1F   SYS mode, IRQs on }
    { $02000030 } $E121F005,   { MSR CPSR_c, R5 }
    { $02000034 } $E5946100,   { LDR R6, [R4, #$100]  ticks++ loop }
    { $02000038 } $E2866001,   { ADD R6, R6, #1 }
    { $0200003C } $E5846100,   { STR R6, [R4, #$100] }
    { $02000040 } $EAFFFFFB,   { B -20 → back to $34 }
    { $02000044 } $00000000,   { padding }
    { $02000048 } $00000000,
    { $0200004C } $00000000,
    { $02000050 } $03000000    { literal: IWRAM base }
  );
  { Handler at $03000200. Logic:
      Load IO base from literal
      Load current hofs/vofs from IWRAM[$110]/[$114]
      Increment them
      Store back to IWRAM
      Store to BG0HOFS/BG0VOFS in I/O
      Increment vblanks counter
      Ack IF (write 1 to bit 0 of $04000202 — real write-1-clear)
      Return
    Layout:
      $03000200: MOV R7, #$03000000    E3A07403
      $03000204: LDR R8, [R7, #$110]   E5978110  ; hofs
      $03000208: ADD R8, R8, #1        E2888001
      $0300020C: STR R8, [R7, #$110]   E5878110
      $03000210: LDR R9, [PC, #$30]    E59F9030  ; load IO base from pool addr=$03000218+$30=$03000248
      $03000214: STRH R8, [R9, #$10]   E1C981B0  ; BG0HOFS
      $03000218: LDR R8, [R7, #$114]   E5978114  ; vofs
      $0300021C: ADD R8, R8, #2        E2888002  ; vofs += 2
      $03000220: STR R8, [R7, #$114]   E5878114
      $03000224: STRH R8, [R9, #$12]   E1C981B2  ; BG0VOFS
      $03000228: LDR R10, [R7, #$104]  E5978104  ; vblanks++
        Hmm R10 in ARM is fine, but our Rd field is 4 bits = 0..15. R10=10=A.
        LDR R10, [R7, #$104]: cond=E 01 I=0 P=1 U=1 B=0 W=0 L=1 Rn=7 Rd=A
          = 1110 0101 1001 0111 1010 0001 0000 0100 = E597A104
      $0300022C: ADD R10, R10, #1      E28AA001
      $03000230: STR R10, [R7, #$104]  E587A104
      $03000234: LDR R11, [PC, #$08]   E59FB008  ; load IF addr from pool addr=$0300023C+$08=$03000244
      $03000238: MOV R0, #1            E3A00001  ; ack V-blank bit (write-1-clear)
      $0300023C: STRH R0, [R11, #0]    E1CB00B0
      $03000240: SUBS PC, LR, #4       E25EF004
      $03000244: literal $04000202
      $03000248: literal $04000000     ; IO base for the BG scroll writes
  }
  Handler: array of TWord = (
    $E3A07403, $E5978110, $E2888001, $E5878110,
    $E59F9030, $E1C981B0, $E5978114, $E2888002,
    $E5878114, $E1C981B2, $E597A104, $E28AA001,
    $E587A104, $E59FB008, $E3A00001, $E1CB00B0,
    $E25EF004,
    $04000202,           { literal at offset 0x44 from handler base = $03000244 }
    $04000000            { literal at offset 0x48 = $03000248 }
  );
var
  i: Integer;
begin
  for i := 0 to High(Prog) do
    mem.WriteWord($02000000 + TWord(i) * 4, Prog[i]);
  for i := 0 to High(Handler) do
    mem.WriteWord($03000200 + TWord(i) * 4, Handler[i]);

  { IRQ vector at $18: LDR PC, [PC, #0] with handler address at $20. }
  mem.PokeBiosWord($18, $E59FF000);
  mem.PokeBiosWord($20, $03000200);

  { Reset vector at $00: branch to cart entry at $02000000 — but we
    actually start the CPU at $02000000 directly via SetReg(R_PC). }
end;

var
  mem: TGbaMemory;
  cpu: TArmCore;
  gpu: TGbaPpu;
  disp: TGbaDisplay;
  intc: TGbaIrq;
  tmrs: TGbaTimers;
  kbd:  TGbaInput;

  frame: Int64;
  scanline: Integer;
  cycle: Integer;
  qpcFreq, startTs, endTs: Int64;
  elapsedSec: Double;
  dispstat: TWord;
begin
  Writeln('Phase D capstone — ARM program drives the GBA.');
  Writeln('Esc closes the window.');

  mem    := TGbaMemory.Create;
  cpu    := TArmCore.Create;
  gpu    := TGbaPpu.Create(mem);
  intc   := TGbaIrq.Create(mem);
  tmrs   := TGbaTimers.Create(mem, intc);
  disp   := TGbaDisplay.Create(WindowScale, 'Pascal GBA — Phase D');
  kbd    := TGbaInput.Create(mem, disp);
  try
    cpu.SetMemoryHooks(@mem.ReadWord, @mem.ReadHalf, @mem.ReadByte,
                       @mem.CpuWriteWord, @mem.CpuWriteHalf, @mem.CpuWriteByte);
    cpu.SetIrqHook(@intc.Pending);
    kbd.UseDefaultMapping;

    SetupScene(mem);
    LoadArmProgram(mem);

    { Start the CPU at the cart entry point. }
    cpu.SetReg(R_PC, $02000000);

    QueryPerformanceFrequency(qpcFreq);
    QueryPerformanceCounter(startTs);

    frame := 0;
    while disp.IsOpen do
    begin
      kbd.Update;

      { Per-scanline schedule: run CPU cycles, tick timers, render visible
        scanline, fire V-blank at scanline 160. }
      for scanline := 0 to SCANLINES_TOTAL - 1 do
      begin
        { Update VCOUNT register. }
        mem.WriteHalf($04000006, THalf(scanline));

        { Run CPU instructions for this scanline. }
        for cycle := 1 to CYCLES_PER_SCANLINE do cpu.Step;
        tmrs.Step(CYCLES_PER_SCANLINE);

        if scanline < SCANLINES_VISIBLE then
        begin
          gpu.RenderScanline(scanline);
        end;

        if scanline = SCANLINES_VISIBLE then
        begin
          { Entering V-blank: set DISPSTAT bit 0 and fire the IRQ. }
          dispstat := mem.ReadHalf($04000004);
          mem.WriteHalf($04000004, THalf(dispstat or $0001));
          intc.Request(IRQ_VBLANK);
        end;
      end;

      { End of frame — clear V-blank flag in DISPSTAT. }
      dispstat := mem.ReadHalf($04000004);
      mem.WriteHalf($04000004, THalf(dispstat and not TWord($1)));

      { Copy framebuffer to display DIB. }
      Move(gpu.FrameBufferPtr^, disp.FrameBufferPtr^,
           GBA_DISPLAY_W * GBA_DISPLAY_H * 4);

      if not disp.Present then Break;
      Inc(frame);

      if frame >= 180 then Break;   { ~3 s auto-close }
    end;

    QueryPerformanceCounter(endTs);
    elapsedSec := (endTs - startTs) / qpcFreq;
    Writeln(Format('Rendered %d frames in %.2f s (%.1f FPS).',
                   [disp.FramesShown, elapsedSec, disp.FramesShown / elapsedSec]));

    Writeln(Format('CPU: ticks=%d, vblanks=%d, scroll=(%d, %d).',
                   [mem.ReadWord($03000100), mem.ReadWord($03000104),
                    mem.ReadWord($03000110), mem.ReadWord($03000114)]));
  finally
    kbd.Free; disp.Free; tmrs.Free; intc.Free; gpu.Free; cpu.Free; mem.Free;
  end;
end.
