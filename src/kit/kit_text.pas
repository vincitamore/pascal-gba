unit Kit_Text;
{
  Tile-grid text on a text BG, fed by a font-bake glyph bank.

  The glyph bank .inc provides 8x8 4bpp glyph tiles plus GLYPH_START /
  GLYPH_COUNT constants (codepoint-contiguous, reading order). Scene
  init loads the glyphs like any tile data, puts the font palette in
  its own bank, then attaches the writer to the text layer:

    BgLoadTiles(1, 0, FONT8_TILES);            -- glyphs -> charblock 1
    BgLoadPaletteBank(15, FONT8_PAL);          -- font colors -> bank 15
    BgControl(1, 1, 10, BG_SIZE_32x32, 0);     -- BG1 = text, in front
    TextAttach(10, 0, FONT8_GLYPH_START, FONT8_GLYPH_COUNT, 15);
    TextWrite(2, 1, 'HELLO');

  The writer targets ONE 32x32 screenblock (a text HUD layer). Cell
  (tx, ty) is tile column/row 0..31 / 0..19 on the visible screen with
  scroll 0. Lowercase input maps to uppercase (small fonts usually
  ship caps-only); a codepoint outside the bank falls back to '?' when
  the bank has one, else to blank.

  Glyph pixel index 0 is the backdrop-transparent slot, so text
  overlays whatever BG layers sit behind it.
}

{$mode objfpc}{$H+}

interface

{ Bind the writer to a screenblock + glyph bank. baseTile is the
  charblock tile index where the bank's first glyph was loaded;
  palBank selects the BG palette bank for every glyph entry. }
procedure TextAttach(screenBase, baseTile, glyphStart, glyphCount,
                     palBank: Integer);

procedure TextPut(tx, ty: Integer; ch: Char);
procedure TextWrite(tx, ty: Integer; const s: shortstring);

{ Blank a w x h cell rectangle (writes the space glyph, or entry 0
  when space is outside the bank). }
procedure TextClearRect(tx, ty, w, h: Integer);

implementation

const
  VRAM_BASE = $06000000;

var
  sb:      Integer = 0;
  base:    Integer = 0;
  gStart:  Integer = 0;
  gCount:  Integer = 0;
  pBank:   Integer = 0;
  blankW:  Word    = 0;      { precomputed entry for space }
  fallbW:  Word    = 0;      { precomputed entry for unknown codepoints }

function GlyphEntry(cp: Integer): Word;
begin
  Result := Word(base + (cp - gStart))
            or Word((pBank and 15) shl 12);
end;

procedure TextAttach(screenBase, baseTile, glyphStart, glyphCount,
                     palBank: Integer);
begin
  sb     := screenBase and 31;
  base   := baseTile;
  gStart := glyphStart;
  gCount := glyphCount;
  pBank  := palBank;
  if (Ord(' ') >= gStart) and (Ord(' ') < gStart + gCount) then
    blankW := GlyphEntry(Ord(' '))
  else
    blankW := 0;
  if (Ord('?') >= gStart) and (Ord('?') < gStart + gCount) then
    fallbW := GlyphEntry(Ord('?'))
  else
    fallbW := blankW;
end;

procedure PutEntry(tx, ty: Integer; entry: Word);
begin
  if (tx < 0) or (tx > 31) or (ty < 0) or (ty > 31) then Exit;
  PWord(VRAM_BASE + LongWord(sb) * $800 +
        LongWord((ty * 32 + tx) * 2))^ := entry;
end;

procedure TextPut(tx, ty: Integer; ch: Char);
var
  cp: Integer;
begin
  cp := Ord(ch);
  if (cp >= Ord('a')) and (cp <= Ord('z')) then
    Dec(cp, 32);                               { lowercase -> caps }
  if (cp >= gStart) and (cp < gStart + gCount) then
    PutEntry(tx, ty, GlyphEntry(cp))
  else
    PutEntry(tx, ty, fallbW);
end;

procedure TextWrite(tx, ty: Integer; const s: shortstring);
var
  k: Integer;
begin
  for k := 1 to Length(s) do
    TextPut(tx + k - 1, ty, s[k]);
end;

procedure TextClearRect(tx, ty, w, h: Integer);
var
  x, y: Integer;
begin
  for y := ty to ty + h - 1 do
    for x := tx to tx + w - 1 do
      PutEntry(x, y, blankW);
end;

end.
