unit Irq;
{
  GBA interrupt controller — three I/O registers + a small dispatch API.

  ── Registers (memory-mapped in I/O) ──

    IE   $04000200  16-bit  Interrupt Enable mask
    IF   $04000202  16-bit  Interrupt Flags (request bits)
    IME  $04000208  16-bit  Master enable (only bit 0 matters)

  ── Sources (bit indices in IE/IF) ──

    bit 0   V-blank
    bit 1   H-blank
    bit 2   V-counter match
    bit 3   Timer 0 overflow
    bit 4   Timer 1 overflow
    bit 5   Timer 2 overflow
    bit 6   Timer 3 overflow
    bit 7   Serial communication
    bit 8   DMA 0
    bit 9   DMA 1
    bit 10  DMA 2
    bit 11  DMA 3
    bit 12  Keypad
    bit 13  Game Pak (cartridge)

  ── Logic ──

  Source X fires an event → set IF bit X (this is `Request`).
  CPU is "about to take an IRQ" iff:
    IME bit 0 = 1
    AND CPSR.I = 0       (this is the CPU's responsibility to check)
    AND (IE AND IF) ≠ 0

  When the CPU takes the IRQ:
    LR_irq ← R[R_PC] + 4
    SPSR_irq ← CPSR
    CPSR mode ← IRQ ; CPSR.I ← 1 ; CPSR.T ← 0
    PC ← $00000018

  The handler at $18 reads IE & IF, decides which source(s) to service,
  WRITES 1 BITS TO IF TO ACK (writing-1-clears semantics — opposite of
  normal registers). Then `SUBS PC, LR, #4` returns to the interrupted
  instruction.

  ── IF writes are "1-clears" (special) ──

  When the CPU writes a halfword to IF, each 1 bit in the written value
  CLEARS that bit in IF (rather than setting it). This is the standard
  ack-IRQ convention. Other bits are preserved.

  Memory is the source of truth for IE/IF/IME. Write-1-clear for IF
  lives in Memory.WriteHalf at $04000202: a CPU STRH AND-NOTs the
  written 1-bits into the live IF halfword. Irq.Request is the hardware
  side — it ORs a source bit into IF via PokeIoHalf, which bypasses
  write-1-clear so a request cannot be eaten as an ack.

  Earlier designs tried a shadow-IF owned by this unit and
  poll-time reconciliation against the flat I/O array. That path was
  removed once Memory gained per-register write semantics; the only
  remaining invariant is "hardware sets IF via PokeIoHalf, CPU acks
  via WriteHalf write-1-clear".
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, GbaTypes, Memory;

const
  REG_IE_ADDR  = $04000200;
  REG_IF_ADDR  = $04000202;
  REG_IME_ADDR = $04000208;

  IRQ_VBLANK   = 0;
  IRQ_HBLANK   = 1;
  IRQ_VCOUNT   = 2;
  IRQ_TIMER0   = 3;
  IRQ_TIMER1   = 4;
  IRQ_TIMER2   = 5;
  IRQ_TIMER3   = 6;
  IRQ_SERIAL   = 7;
  IRQ_DMA0     = 8;
  IRQ_DMA1     = 9;
  IRQ_DMA2     = 10;
  IRQ_DMA3     = 11;
  IRQ_KEYPAD   = 12;
  IRQ_GAMEPAK  = 13;

type
  TGbaIrq = class
  private
    FMem: TGbaMemory;
  public
    constructor Create(mem: TGbaMemory);

    { Set the source's bit in IF (request the interrupt). Memory is now
      the source of truth — Phase F update: write-1-clear semantics
      moved into Memory.WriteHalf at the IF address, so we no longer
      need a shadow. Request OR's into IF via the PokeIoHalf raw-write
      escape (which bypasses write-1-clear semantics — Irq is "the
      hardware" setting the bit, not the CPU clearing it). }
    procedure Request(source: Integer);

    { Compute whether any enabled interrupt is pending. Caller (CPU)
      should also check CPSR.I before taking the exception. }
    function  Pending: Boolean;

    { Raw request check for the CPU's halt-wake path: IE and IF only,
      no IME gate. Per GBATEK, Halt ends whenever an enabled interrupt
      is REQUESTED (IE and IF <> 0) regardless of IME; IME only gates
      whether the woken CPU vectors to the handler. Open-source BIOS
      boot code relies on this (it Halts with IE set and IME off). }
    function  PendingRaw: Boolean;

    { Read the live IE / IF / IME values from memory (utility). }
    function  ReadIE:  TWord;
    function  ReadIF:  TWord;
    function  ReadIME: TWord;
  end;

implementation

constructor TGbaIrq.Create(mem: TGbaMemory);
begin
  inherited Create;
  FMem := mem;
  FMem.PokeIoHalf(REG_IF_ADDR and $FFF, 0);
end;

function TGbaIrq.ReadIE: TWord;
begin
  Result := TWord(FMem.ReadHalf(REG_IE_ADDR));
end;

function TGbaIrq.ReadIF: TWord;
begin
  Result := TWord(FMem.ReadHalf(REG_IF_ADDR));
end;

function TGbaIrq.ReadIME: TWord;
begin
  Result := TWord(FMem.ReadHalf(REG_IME_ADDR));
end;

procedure TGbaIrq.Request(source: Integer);
{ Set the source's bit in IF. We use PokeIoHalf because the normal
  Memory.WriteHalf path would interpret our write as a CPU ack (write-
  1-clear). Irq IS the hardware setting the bit; we go around the
  CPU-facing semantics. }
var
  cur: THalf;
begin
  if (source < 0) or (source > 13) then Exit;
  cur := FMem.ReadHalf(REG_IF_ADDR);
  cur := cur or (THalf(1) shl source);
  FMem.PokeIoHalf(REG_IF_ADDR and $FFF, cur);
end;

function TGbaIrq.PendingRaw: Boolean;
var
  ie, ifVal: TWord;
begin
  ie    := TWord(FMem.ReadHalf(REG_IE_ADDR));
  ifVal := TWord(FMem.ReadHalf(REG_IF_ADDR));
  Result := (ie and ifVal) <> 0;
end;

function TGbaIrq.Pending: Boolean;
var
  ime, ie, ifVal: TWord;
begin
  ime := TWord(FMem.ReadHalf(REG_IME_ADDR));
  if (ime and 1) = 0 then Exit(False);
  ie    := TWord(FMem.ReadHalf(REG_IE_ADDR));
  ifVal := TWord(FMem.ReadHalf(REG_IF_ADDR));
  Result := (ie and ifVal) <> 0;
end;

end.
