unit Display;
{
  Win32 display path for the GBA emulator with a frameless window and
  hand-rolled window chrome. Same layout idea as custom LCL form chrome
  (title bar + client + status), implemented here against the raw Win32
  surface rather than TForm.

  ── Layout ──

    +--------------------------------------------------------------+
    | * Pascal GBA - <ROM title>               _   []   X          |   TITLE_BAR_H (32 px)
    +--------------------------------------------------------------+
    |                                                              |
    |                                                              |
    |                  GBA framebuffer (scaled)                    |   GBA_DISPLAY_H * scale
    |                                                              |
    |                                                              |
    +--------------------------------------------------------------+
    | Z=A  X=B  Enter=Start  Bksp=Sel  Q=L  W=R  + Arrows | Esc... |   STATUS_BAR_H (22 px)
    +--------------------------------------------------------------+

  ── Drag + resize ──

  Title-bar mouse-down (outside the three buttons) sends Windows
  WM_NCLBUTTONDOWN HTCAPTION so the OS handles drag + Aero Snap
  natively. WS_POPUP keeps us out of the native non-client paint
  path so we own the entire surface.

  ── Status bar ──

  Always-visible keymap reference. Replaces the first-build failure
  mode where controls were undiscoverable without a modal. Persistent
  — no modal needed for basic discoverability.

  ── Real-time pacing ──

  - `timeBeginPeriod(1)` at construction → 1 ms sleep granularity.
  - QPC-based pacing in Present(): if the target frame time hasn't
    elapsed, Sleep the remainder.
  - Direct DIB blit: no intermediate canvas, no LCL widget chain.
    The chrome and status bar rendering also goes straight to the
    window HDC via GDI — no per-frame allocation.
}

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Types, Windows, GbaTypes;

function timeBeginPeriod(uPeriod: DWORD): DWORD; stdcall; external 'winmm.dll' name 'timeBeginPeriod';
function timeEndPeriod(uPeriod: DWORD): DWORD; stdcall; external 'winmm.dll' name 'timeEndPeriod';

const
  GBA_DISPLAY_W = 240;
  GBA_DISPLAY_H = 160;

  TITLE_BAR_H  = 32;
  BTN_W        = 46;
  BTN_COUNT    = 3;

  { Dark palette (Windows COLORREF = BGR order). }
  COLOR_BG_TITLE   = $00141414;
  COLOR_BG_STATUS  = $00181818;
  COLOR_BG_HOVER   = $002D2D2D;
  COLOR_FG         = $00E5E5E5;
  COLOR_FG_MID     = $00CFCFCF;
  COLOR_FG_DIM     = $00858585;
  COLOR_ACCENT     = $00D69C56;
  COLOR_DANGER     = $004848E5;
  COLOR_BORDER     = $00333333;

  BTN_IDX_MIN    = 0;
  BTN_IDX_MAX    = 1;
  BTN_IDX_CLOSE  = 2;
type
  TGbaDisplay = class
  private
    FHwnd:        HWND;
    FHdc:         HDC;
    FMemDc:       HDC;
    FDibBitmap:   HBITMAP;
    FDibBits:     Pointer;          { 240×160 ARGB written by the PPU }
    FOldBitmap:   HBITMAP;
    FScale:       Integer;
    FRunning:     Boolean;
    FKeys:        array[0..255] of Boolean;
    FQpcFreq:     Int64;
    FNextFrameTs: Int64;
    FFramesShown: Int64;
    FDumpRequested: Boolean;        { F12 sets, gba_runner reads + clears }

    FTitleText:   string;
    FBtnHover:    Integer;          { -1 = none, else BTN_IDX_* }
    FTracking:    Boolean;          { we requested TrackMouseEvent? }

    { Cached fonts so we don't recreate them every frame. }
    FFontTitle:   HFONT;

    { Window dimensions in client coords (= entire window for WS_POPUP). }
    FClientW:     Integer;
    FClientH:     Integer;

    procedure CreateWindowAndDib(scale: Integer; const title: string);
    procedure DestroyWindowAndDib;

    procedure RenderChrome(targetDc: HDC);
    function  ButtonRect(idx: Integer): TRect;
    function  HitTestButton(x, y: Integer): Integer;
  public
    constructor Create(scale: Integer; const title: string);
    destructor  Destroy; override;

    { Returns a pointer to the 240*160 word DIB the PPU writes to. }
    function  FrameBufferPtr: Pointer;

    { Blit framebuffer + render chrome + pump messages + pace 60 FPS.
      Returns False when the window has been closed. }
    function  Present: Boolean;

    function  KeyPressed(vk: Integer): Boolean;

    { Window-proc message handlers — public so the static WndProc can
      delegate. }
    procedure OnLButtonDown(x, y: Integer);
    procedure OnLButtonDblClk(x, y: Integer);
    procedure OnMouseMove(x, y: Integer);
    procedure OnMouseLeave;
    procedure OnPaint(hdcPaint: HDC);

    property  IsOpen: Boolean read FRunning;
    property  FramesShown: Int64 read FFramesShown;
    property  DumpRequested: Boolean read FDumpRequested write FDumpRequested;
  end;

implementation

const
  WINDOW_CLASS_NAME = 'GbaPascalDisplay';

var
  GActiveDisplay: TGbaDisplay = nil;

function MakeRect(l, t, r, b: Integer): TRect;
begin
  Result.Left   := l;
  Result.Top    := t;
  Result.Right  := r;
  Result.Bottom := b;
end;

function GbaWndProc(hwnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  vk: Integer;
  ps: TPaintStruct;
  hdcPaint: HDC;
  x, y: Integer;
begin
  case uMsg of
    WM_CLOSE:
      begin
        if Assigned(GActiveDisplay) then GActiveDisplay.FRunning := False;
        DestroyWindow(hwnd);
        Result := 0;
        Exit;
      end;
    WM_DESTROY:
      begin
        PostQuitMessage(0);
        if Assigned(GActiveDisplay) then GActiveDisplay.FRunning := False;
        Result := 0;
        Exit;
      end;
    WM_KEYDOWN:
      begin
        vk := Integer(wParam);
        if Assigned(GActiveDisplay) and (vk >= 0) and (vk < 256) then
          GActiveDisplay.FKeys[vk] := True;
        if vk = VK_ESCAPE then PostMessage(hwnd, WM_CLOSE, 0, 0);
        if (vk = VK_F12) and Assigned(GActiveDisplay) then GActiveDisplay.FDumpRequested := True;
        Result := 0;
        Exit;
      end;
    WM_KEYUP:
      begin
        vk := Integer(wParam);
        if Assigned(GActiveDisplay) and (vk >= 0) and (vk < 256) then
          GActiveDisplay.FKeys[vk] := False;
        Result := 0;
        Exit;
      end;
    WM_LBUTTONDOWN:
      begin
        x := SmallInt(LoWord(DWORD(lParam)));
        y := SmallInt(HiWord(DWORD(lParam)));
        if Assigned(GActiveDisplay) then GActiveDisplay.OnLButtonDown(x, y);
        Result := 0;
        Exit;
      end;
    WM_LBUTTONDBLCLK:
      begin
        x := SmallInt(LoWord(DWORD(lParam)));
        y := SmallInt(HiWord(DWORD(lParam)));
        if Assigned(GActiveDisplay) then GActiveDisplay.OnLButtonDblClk(x, y);
        Result := 0;
        Exit;
      end;
    WM_MOUSEMOVE:
      begin
        x := SmallInt(LoWord(DWORD(lParam)));
        y := SmallInt(HiWord(DWORD(lParam)));
        if Assigned(GActiveDisplay) then GActiveDisplay.OnMouseMove(x, y);
        Result := 0;
        Exit;
      end;
    WM_MOUSELEAVE:
      begin
        if Assigned(GActiveDisplay) then GActiveDisplay.OnMouseLeave;
        Result := 0;
        Exit;
      end;
    WM_PAINT:
      begin
        hdcPaint := BeginPaint(hwnd, ps);
        try
          if Assigned(GActiveDisplay) then GActiveDisplay.OnPaint(hdcPaint);
        finally
          EndPaint(hwnd, ps);
        end;
        Result := 0;
        Exit;
      end;
    WM_ERASEBKGND:
      begin
        { We paint everything ourselves. Returning non-zero tells Windows
          not to clear with the class background brush. }
        Result := 1;
        Exit;
      end;
  end;
  Result := DefWindowProc(hwnd, uMsg, wParam, lParam);
end;

procedure TGbaDisplay.CreateWindowAndDib(scale: Integer; const title: string);
var
  wc: WNDCLASSEX;
  bmi: BITMAPINFO;
  windowW, windowH: Integer;
  style, styleEx: DWORD;
  hInst: THandle;
begin
  FTitleText := title;
  FBtnHover  := -1;
  FTracking  := False;
  hInst      := Windows.GetModuleHandle(nil);

  FillChar(wc, SizeOf(wc), 0);
  wc.cbSize        := SizeOf(wc);
  wc.style         := CS_OWNDC or CS_DBLCLKS;       { CS_DBLCLKS → WM_LBUTTONDBLCLK }
  wc.lpfnWndProc   := WNDPROC(@GbaWndProc);
  wc.hInstance     := hInst;
  wc.hCursor       := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := 0;                            { we own all painting }
  wc.lpszClassName := PChar(WINDOW_CLASS_NAME);
  RegisterClassEx(wc);

  { Frameless window: WS_POPUP gives us a borderless rectangle that's
    100% client area. We render title bar + framebuffer + status bar
    via GDI. WS_VISIBLE so it shows immediately. CS_DBLCLKS at class
    level so we get WM_LBUTTONDBLCLK on title-bar double-click. }
  windowW := GBA_DISPLAY_W * scale;
  windowH := GBA_DISPLAY_H * scale + TITLE_BAR_H;
  FClientW := windowW;
  FClientH := windowH;
  style   := WS_POPUP or WS_VISIBLE;
  styleEx := WS_EX_APPWINDOW;                       { show in taskbar despite WS_POPUP }

  FHwnd := CreateWindowEx(
    styleEx,
    WINDOW_CLASS_NAME,
    PChar(title),
    style,
    CW_USEDEFAULT, CW_USEDEFAULT,
    windowW, windowH,
    0, 0,
    hInst,
    nil
  );
  if FHwnd = 0 then
    raise Exception.Create('Display: CreateWindowEx failed');

  ShowWindow(FHwnd, SW_SHOW);
  UpdateWindow(FHwnd);
  Windows.SetForegroundWindow(FHwnd);
  Windows.SetFocus(FHwnd);

  FHdc := GetDC(FHwnd);
  if FHdc = 0 then
    raise Exception.Create('Display: GetDC failed');

  FMemDc := CreateCompatibleDC(FHdc);
  if FMemDc = 0 then
    raise Exception.Create('Display: CreateCompatibleDC failed');

  FillChar(bmi, SizeOf(bmi), 0);
  bmi.bmiHeader.biSize        := SizeOf(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth       := GBA_DISPLAY_W;
  bmi.bmiHeader.biHeight      := -GBA_DISPLAY_H;
  bmi.bmiHeader.biPlanes      := 1;
  bmi.bmiHeader.biBitCount    := 32;
  bmi.bmiHeader.biCompression := BI_RGB;

  FDibBitmap := CreateDIBSection(FMemDc, BITMAPINFO(bmi), DIB_RGB_COLORS, FDibBits, 0, 0);
  if (FDibBitmap = 0) or (FDibBits = nil) then
    raise Exception.Create('Display: CreateDIBSection failed');

  FOldBitmap := HBITMAP(SelectObject(FMemDc, FDibBitmap));

  FillChar(FDibBits^, GBA_DISPLAY_W * GBA_DISPLAY_H * 4, $20);

  { Pre-create fonts. Segoe UI for title + status; Segoe UI Symbol for
    the button glyphs. lfHeight is negative = cell height (excludes
    line gap), the usual modern convention. }
  FFontTitle  := CreateFont(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, ANSI_CHARSET,
    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, 5 {CLEARTYPE_QUALITY},
    DEFAULT_PITCH or FF_SWISS, 'Segoe UI');
end;

procedure TGbaDisplay.DestroyWindowAndDib;
begin
  if FFontTitle  <> 0 then begin DeleteObject(FFontTitle);  FFontTitle  := 0; end;

  if FMemDc <> 0 then
  begin
    if FOldBitmap <> 0 then SelectObject(FMemDc, FOldBitmap);
    DeleteDC(FMemDc);
    FMemDc := 0;
  end;
  if FDibBitmap <> 0 then
  begin
    DeleteObject(FDibBitmap);
    FDibBitmap := 0;
    FDibBits   := nil;
  end;
  if (FHwnd <> 0) and (FHdc <> 0) then
  begin
    ReleaseDC(FHwnd, FHdc);
    FHdc := 0;
  end;
  if FHwnd <> 0 then
  begin
    DestroyWindow(FHwnd);
    FHwnd := 0;
  end;
end;

function TGbaDisplay.ButtonRect(idx: Integer): TRect;
{ Three buttons docked to the right edge of the title bar, ordered
  MIN | MAX | CLOSE (left to right) — same convention as Windows. }
begin
  Result.Right  := FClientW - (BTN_COUNT - 1 - idx) * BTN_W;
  Result.Left   := Result.Right - BTN_W;
  Result.Top    := 0;
  Result.Bottom := TITLE_BAR_H;
end;

function TGbaDisplay.HitTestButton(x, y: Integer): Integer;
var
  i: Integer;
  r: TRect;
begin
  if (y < 0) or (y >= TITLE_BAR_H) then Exit(-1);
  for i := 0 to BTN_COUNT - 1 do
  begin
    r := ButtonRect(i);
    if (x >= r.Left) and (x < r.Right) then Exit(i);
  end;
  Result := -1;
end;

procedure TGbaDisplay.RenderChrome(targetDc: HDC);
{ Render the title bar — background fill, app glyph + title text on
  the left, three GDI-drawn icon buttons (min/max/close) on the right.
  Icons are drawn via GDI primitives instead of Unicode glyphs so
  rendering is consistent across font availability and we don't fight
  Segoe UI Symbol's tall-bracket layout for the maximize glyph. }
var
  brushTitle, brushHover, brushBorder: HBRUSH;
  oldFont, oldPen: HGDIOBJ;
  pen: HPEN;
  r: TRect;
  i, cx, cy: Integer;
begin
  brushTitle  := CreateSolidBrush(COLORREF(COLOR_BG_TITLE));
  brushHover  := CreateSolidBrush(COLORREF(COLOR_BG_HOVER));
  brushBorder := CreateSolidBrush(COLORREF(COLOR_BORDER));
  try
    { Title bar background. }
    r := MakeRect(0, 0, FClientW, TITLE_BAR_H);
    FillRect(targetDc, r, brushTitle);

    { App title text, left-aligned. }
    SetBkMode(targetDc, TRANSPARENT);
    oldFont := SelectObject(targetDc, FFontTitle);
    try
      SetTextColor(targetDc, COLORREF(COLOR_ACCENT));
      r := MakeRect(12, 0, FClientW - BTN_W * BTN_COUNT - 4, TITLE_BAR_H);
      DrawText(targetDc, PChar(FTitleText), -1, @r,
               DT_VCENTER or DT_SINGLELINE or DT_END_ELLIPSIS or DT_LEFT);
    finally
      SelectObject(targetDc, oldFont);
    end;

    { Window-control buttons — hover backgrounds + GDI-drawn icons. }
    for i := 0 to BTN_COUNT - 1 do
    begin
      r := ButtonRect(i);
      if FBtnHover = i then
      begin
        if i = BTN_IDX_CLOSE then
          FillRect(targetDc, r, CreateSolidBrush(COLORREF(COLOR_DANGER)))
        else
          FillRect(targetDc, r, brushHover);
      end;

      { Pen for the icon strokes — white on hover (better contrast),
        muted otherwise. }
      if (FBtnHover = i) then
        pen := CreatePen(PS_SOLID, 1, COLORREF(COLOR_FG))
      else
        pen := CreatePen(PS_SOLID, 1, COLORREF(COLOR_FG_MID));
      oldPen := SelectObject(targetDc, pen);
      try
        cx := (r.Left + r.Right) div 2;
        cy := (r.Top + r.Bottom) div 2;
        case i of
          BTN_IDX_MIN:
            begin
              { Horizontal line at vertical center. }
              MoveToEx(targetDc, cx - 5, cy, nil);
              LineTo(targetDc, cx + 6, cy);
            end;
          BTN_IDX_MAX:
            begin
              { Outlined square at center — 10×10. }
              MoveToEx(targetDc, cx - 5, cy - 5, nil);
              LineTo(targetDc, cx + 5, cy - 5);
              LineTo(targetDc, cx + 5, cy + 5);
              LineTo(targetDc, cx - 5, cy + 5);
              LineTo(targetDc, cx - 5, cy - 5);
            end;
          BTN_IDX_CLOSE:
            begin
              { Two diagonals forming an X — 10×10. }
              MoveToEx(targetDc, cx - 5, cy - 5, nil);
              LineTo(targetDc, cx + 6, cy + 6);
              MoveToEx(targetDc, cx + 5, cy - 5, nil);
              LineTo(targetDc, cx - 6, cy + 6);
            end;
        end;
      finally
        SelectObject(targetDc, oldPen);
        DeleteObject(pen);
      end;
    end;

    { 1-px accent line between title bar and framebuffer. }
    r := MakeRect(0, TITLE_BAR_H - 1, FClientW, TITLE_BAR_H);
    FillRect(targetDc, r, brushBorder);
  finally
    DeleteObject(brushTitle);
    DeleteObject(brushHover);
    DeleteObject(brushBorder);
  end;
end;

procedure TGbaDisplay.OnLButtonDown(x, y: Integer);
var
  btn: Integer;
begin
  btn := HitTestButton(x, y);
  case btn of
    BTN_IDX_MIN:
      ShowWindow(FHwnd, SW_MINIMIZE);
    BTN_IDX_MAX:
      { Maximize/restore — for a fixed-aspect emulator, restore makes
        sense as "snap to normal size." Toggle. }
      if IsZoomed(FHwnd) then ShowWindow(FHwnd, SW_RESTORE)
                         else ShowWindow(FHwnd, SW_MAXIMIZE);
    BTN_IDX_CLOSE:
      PostMessage(FHwnd, WM_CLOSE, 0, 0);
  else
    { Not on a button. If in title-bar area, hand off drag to Windows. }
    if y < TITLE_BAR_H then
    begin
      ReleaseCapture;
      SendMessage(FHwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    end;
  end;
end;

procedure TGbaDisplay.OnLButtonDblClk(x, y: Integer);
begin
  { Double-click title bar → maximize/restore (convention). }
  if (y < TITLE_BAR_H) and (HitTestButton(x, y) = -1) then
  begin
    if IsZoomed(FHwnd) then ShowWindow(FHwnd, SW_RESTORE)
                       else ShowWindow(FHwnd, SW_MAXIMIZE);
  end;
end;

procedure TGbaDisplay.OnMouseMove(x, y: Integer);
var
  tme: TTrackMouseEvent;
  newHover: Integer;
begin
  newHover := HitTestButton(x, y);
  if newHover <> FBtnHover then
  begin
    FBtnHover := newHover;
    { Request WM_MOUSELEAVE so we can clear hover when mouse leaves
      the window. Track once per hover-change cycle. }
    if not FTracking then
    begin
      FillChar(tme, SizeOf(tme), 0);
      tme.cbSize    := SizeOf(tme);
      tme.dwFlags   := TME_LEAVE;
      tme.hwndTrack := FHwnd;
      TrackMouseEvent(@tme);
      FTracking := True;
    end;
    InvalidateRect(FHwnd, nil, False);
  end;
end;

procedure TGbaDisplay.OnMouseLeave;
begin
  FTracking := False;
  if FBtnHover <> -1 then
  begin
    FBtnHover := -1;
    InvalidateRect(FHwnd, nil, False);
  end;
end;

procedure TGbaDisplay.OnPaint(hdcPaint: HDC);
begin
  { Render chrome to the supplied DC. Framebuffer is blitted from
    Present() on its own cadence — we don't blit here (would race
    the per-frame Present() update). The framebuffer area might
    flicker briefly on WM_PAINT before the next Present() catches
    up, which is acceptable. }
  RenderChrome(hdcPaint);
end;

constructor TGbaDisplay.Create(scale: Integer; const title: string);
begin
  inherited Create;
  FillChar(FKeys, SizeOf(FKeys), 0);
  FScale := scale;
  FRunning := True;
  FFramesShown := 0;
  FBtnHover := -1;

  timeBeginPeriod(1);

  QueryPerformanceFrequency(FQpcFreq);
  QueryPerformanceCounter(FNextFrameTs);

  GActiveDisplay := Self;
  CreateWindowAndDib(scale, title);
end;

destructor TGbaDisplay.Destroy;
begin
  DestroyWindowAndDib;
  timeEndPeriod(1);
  if GActiveDisplay = Self then GActiveDisplay := nil;
  inherited Destroy;
end;

function TGbaDisplay.FrameBufferPtr: Pointer;
begin
  Result := FDibBits;
end;

function TGbaDisplay.KeyPressed(vk: Integer): Boolean;
begin
  if (vk >= 0) and (vk < 256) then Result := FKeys[vk]
                              else Result := False;
end;

function TGbaDisplay.Present: Boolean;
const
  TargetFrameTicks: Int64 = 0;
var
  msg: TMsg;
  now: Int64;
  remaining: Int64;
  remainingMs: DWORD;
begin
  Result := FRunning;
  if not Result then Exit;

  if TargetFrameTicks = 0 then TargetFrameTicks := FQpcFreq div 60;

  while PeekMessage(@msg, 0, 0, 0, PM_REMOVE) do
  begin
    if msg.message = WM_QUIT then
    begin
      FRunning := False;
      Result := False;
      Exit;
    end;
    TranslateMessage(@msg);
    DispatchMessage(@msg);
  end;

  if not FRunning then
  begin
    Result := False;
    Exit;
  end;

  { Render chrome first (cheap — fills two strips at top and bottom).
    Then blit the framebuffer into the middle. Order matters: chrome
    fills are constant-time fills; framebuffer is the big StretchBlt
    and we want it to land on top (paint over any residual). }
  RenderChrome(FHdc);

  StretchBlt(
    FHdc,
    0, TITLE_BAR_H, GBA_DISPLAY_W * FScale, GBA_DISPLAY_H * FScale,
    FMemDc,
    0, 0, GBA_DISPLAY_W, GBA_DISPLAY_H,
    SRCCOPY
  );
  Inc(FFramesShown);

  QueryPerformanceCounter(now);
  remaining := FNextFrameTs - now;
  if remaining > 0 then
  begin
    { Undersleep by 1 ms, then spin to the exact tick: Sleep() can
      overshoot by up to its granularity, and every overshoot used to
      make the frame "late" below. }
    remainingMs := DWORD((remaining * 1000) div FQpcFreq);
    if remainingMs > 1 then Sleep(remainingMs - 1);
    repeat
      QueryPerformanceCounter(now);
    until now >= FNextFrameTs;
    Inc(FNextFrameTs, TargetFrameTicks);
  end
  else
  begin
    { Late frame: keep the schedule so small overruns are repaid by
      the following frames. The old behavior re-anchored the schedule
      on EVERY late frame, permanently dropping the deficit — measured
      as a systematic ~2-3% slowdown (tempo drag) in windowed mode.
      Only re-anchor after a gross stall. }
    if (-remaining) > TargetFrameTicks * 8 then
      FNextFrameTs := now + TargetFrameTicks
    else
      Inc(FNextFrameTs, TargetFrameTicks);
  end;
end;

end.
