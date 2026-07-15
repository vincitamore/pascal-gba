unit MainForm;
{
  gbashell — Pascal GBA emulator launcher with custom dark chrome.
  Frameless TForm + hand-rolled title bar drag/resize; native Windows
  behaviors (Aero Snap, taskbar integration, alt-tab,
  restore-on-double-click) come free via the WM_NCLBUTTONDOWN + HT*
  hit-code trick: release the LCL's mouse capture, then hand the drag
  to the OS with the appropriate hit-test code.

  ── Layout ──

    ┌───────────────────────────────────────────────────────────────┐
    │ ⚡ Pascal GBA                              _   □   ✕         │ ← title bar 32px
    ├───────────────────────────────────────────────────────────────┤
    │                                                               │
    │  Pascal GBA   (accent, big)                                   │
    │  status / running…                                            │
    │                                                               │
    │  BIOS:  [ path …………………………]  [ Browse… ]                       │
    │                                                               │
    │  [           Open ROM…                              ]         │
    │                                                               │
    │  Recent ROMs (double-click to launch):                        │
    │  ┌──────────────────────────────────────────────────────┐     │
    │  │                                                      │     │
    │  │  (recent list)                                       │     │
    │  │                                                      │     │
    │  └──────────────────────────────────────────────────────┘     │
    │                                                       [Quit]  │
    └───────────────────────────────────────────────────────────────┘

  ── Recent-ROMs persistence ──

  %APPDATA%\PascalGBA\recent.txt, one path per line, most-recent first,
  up to 8 entries.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs,
  Graphics, LCLType, Windows, Messages, Gba_Runner;

const
  { Dark launcher palette (BGR — TColor is little-endian-bytes). }
  COLOR_BG          = TColor($00181818);
  COLOR_BG_PANEL    = TColor($001E1E1E);
  COLOR_BG_BTN      = TColor($00252525);
  COLOR_BG_HOVER    = TColor($002D2D2D);
  COLOR_BG_TITLE    = TColor($00141414);
  COLOR_BG_RULE     = TColor($00333333);
  COLOR_FG          = TColor($00E5E5E5);
  COLOR_FG_MID      = TColor($00CFCFCF);
  COLOR_FG_DIM      = TColor($00858585);
  COLOR_ACCENT      = TColor($00D69C56);
  COLOR_DANGER      = TColor($004848E5);

  TITLE_BAR_H       = 32;
  RESIZE_BORDER     = 6;

  APP_TITLE         = 'Pascal GBA';
  RECENT_MAX        = 8;
  RECENT_DIR        = 'PascalGBA';
  RECENT_FILE       = 'recent.txt';
  DEFAULT_BIOS      = 'bios\gba_bios.bin';

type
  TGbaShellForm = class(TForm)
  private
    { Title bar. }
    FTitleBar:     TPanel;
    FTitleText:    TLabel;
    FBtnMin:       TPaintBox;
    FBtnMax:       TPaintBox;
    FBtnClose:     TPaintBox;
    FBtnMinHover:  Boolean;
    FBtnMaxHover:  Boolean;
    FBtnCloseHover: Boolean;

    { Body. }
    FHeader:       TLabel;
    FStatusLabel:  TLabel;
    FBiosLabel:    TLabel;
    FBiosEdit:     TEdit;
    FBiosBrowse:   TButton;
    FOpenButton:   TButton;
    FRecentLabel:  TLabel;
    FRecentList:   TListBox;
    FControlsHeader: TLabel;
    FControlsView:   TMemo;
    FQuitButton:   TButton;

    FRecent:       TStringList;

    function  RecentPath: string;
    function  ResolveDefaultBios: string;
    function  ResolveDefaultRomDir: string;
    procedure LoadRecent;
    procedure SaveRecent;
    procedure AddRecent(const romPath: string);
    procedure RefreshRecentList;

    procedure BuildChrome;
    procedure BuildBody;

    { Title-bar interactions. }
    procedure TitleBarMouseDown(Sender: TObject; Button: TMouseButton;
                                Shift: TShiftState; X, Y: Integer);
    procedure TitleBarDblClick(Sender: TObject);

    { Form-edge resize. }
    procedure FormMouseMoveHandler(Sender: TObject; Shift: TShiftState;
                                   X, Y: Integer);
    procedure FormMouseDownHandler(Sender: TObject; Button: TMouseButton;
                                   Shift: TShiftState; X, Y: Integer);

    { Window-button click + hover. }
    procedure BtnMinClick(Sender: TObject);
    procedure BtnMaxClick(Sender: TObject);
    procedure BtnCloseClick(Sender: TObject);
    procedure BtnMinEnter(Sender: TObject);
    procedure BtnMinLeave(Sender: TObject);
    procedure BtnMaxEnter(Sender: TObject);
    procedure BtnMaxLeave(Sender: TObject);
    procedure BtnCloseEnter(Sender: TObject);
    procedure BtnCloseLeave(Sender: TObject);
    procedure PaintChromeButton(Sender: TObject);

    { Body interactions. }
    procedure OnOpenClick(Sender: TObject);
    procedure OnBiosBrowseClick(Sender: TObject);
    procedure OnQuitClick(Sender: TObject);
    procedure OnRecentDblClick(Sender: TObject);

    procedure LaunchEmulator(const romPath: string);
    procedure SetStatus(const msg: string);
  public
    constructor Create(AOwner: TComponent); override;
    procedure   FormCloseHandler(Sender: TObject; var CloseAction: TCloseAction);
  end;

var
  GbaShellForm: TGbaShellForm;

implementation

{ ───── TGbaShellForm ──────────────────────────────────────────────── }

constructor TGbaShellForm.Create(AOwner: TComponent);
begin
  { CreateNew bypasses .lfm loading — layout is built in code. }
  inherited CreateNew(AOwner);
  Caption       := APP_TITLE;
  Width         := 540;
  Height        := 670;
  Position      := poScreenCenter;
  Color         := COLOR_BG;
  Font.Name     := 'Segoe UI';
  Font.Size     := 10;
  Font.Color    := COLOR_FG;
  BorderStyle   := bsNone;         { frameless — we draw all chrome }
  KeyPreview    := True;
  OnClose       := @FormCloseHandler;
  OnMouseMove   := @FormMouseMoveHandler;
  OnMouseDown   := @FormMouseDownHandler;

  BuildChrome;
  BuildBody;

  FRecent := TStringList.Create;
  LoadRecent;
  RefreshRecentList;
end;

procedure TGbaShellForm.BuildChrome;
begin
  { Title bar — fixed-height panel docked at top. Color is slightly
    darker than the form background so it visually separates as a
    "chrome strip." }
  FTitleBar := TPanel.Create(Self);
  FTitleBar.Parent := Self;
  FTitleBar.Align := alTop;
  FTitleBar.Height := TITLE_BAR_H;
  FTitleBar.Color := COLOR_BG_TITLE;
  FTitleBar.BevelOuter := bvNone;
  FTitleBar.BevelInner := bvNone;
  FTitleBar.ParentColor := False;
  FTitleBar.OnMouseDown := @TitleBarMouseDown;
  FTitleBar.OnDblClick := @TitleBarDblClick;

  { App icon glyph + name, left-aligned. }
  FTitleText := TLabel.Create(Self);
  FTitleText.Parent := FTitleBar;
  FTitleText.Left := 12;
  FTitleText.Top  := 8;
  FTitleText.Caption := '⚡  ' + APP_TITLE;
  FTitleText.Font.Color := COLOR_FG_MID;
  FTitleText.Font.Size := 9;
  FTitleText.Transparent := True;
  FTitleText.OnMouseDown := @TitleBarMouseDown;
  FTitleText.OnDblClick := @TitleBarDblClick;

  { Right side button trio: MIN | MAX | CLOSE (Windows convention,
    close on far right). TPaintBox + GDI primitives so the launcher
    chrome buttons match the emulator window's chrome exactly. }
  FBtnMin := TPaintBox.Create(Self);
  FBtnMin.Parent := FTitleBar;
  FBtnMin.SetBounds(FTitleBar.Width - 3 * 46, 0, 46, TITLE_BAR_H);
  FBtnMin.Anchors := [akTop, akRight];
  FBtnMin.Cursor := crHandPoint;
  FBtnMin.OnPaint := @PaintChromeButton;
  FBtnMin.OnClick := @BtnMinClick;
  FBtnMin.OnMouseEnter := @BtnMinEnter;
  FBtnMin.OnMouseLeave := @BtnMinLeave;

  FBtnMax := TPaintBox.Create(Self);
  FBtnMax.Parent := FTitleBar;
  FBtnMax.SetBounds(FTitleBar.Width - 2 * 46, 0, 46, TITLE_BAR_H);
  FBtnMax.Anchors := [akTop, akRight];
  FBtnMax.Cursor := crHandPoint;
  FBtnMax.OnPaint := @PaintChromeButton;
  FBtnMax.OnClick := @BtnMaxClick;
  FBtnMax.OnMouseEnter := @BtnMaxEnter;
  FBtnMax.OnMouseLeave := @BtnMaxLeave;

  FBtnClose := TPaintBox.Create(Self);
  FBtnClose.Parent := FTitleBar;
  FBtnClose.SetBounds(FTitleBar.Width - 1 * 46, 0, 46, TITLE_BAR_H);
  FBtnClose.Anchors := [akTop, akRight];
  FBtnClose.Cursor := crHandPoint;
  FBtnClose.OnPaint := @PaintChromeButton;
  FBtnClose.OnClick := @BtnCloseClick;
  FBtnClose.OnMouseEnter := @BtnCloseEnter;
  FBtnClose.OnMouseLeave := @BtnCloseLeave;
end;

procedure TGbaShellForm.BuildBody;
begin
  FHeader := TLabel.Create(Self);
  FHeader.Parent := Self;
  FHeader.SetBounds(20, TITLE_BAR_H + 16, 500, 32);
  FHeader.Caption := APP_TITLE;
  FHeader.Font.Color := COLOR_ACCENT;
  FHeader.Font.Size := 18;
  FHeader.Font.Style := [fsBold];
  FHeader.Transparent := True;

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Self;
  FStatusLabel.SetBounds(20, TITLE_BAR_H + 50, 500, 20);
  FStatusLabel.Caption := 'Pick a ROM, or pick from recent.';
  FStatusLabel.Font.Color := COLOR_FG_DIM;
  FStatusLabel.Font.Size := 9;
  FStatusLabel.Transparent := True;

  FBiosLabel := TLabel.Create(Self);
  FBiosLabel.Parent := Self;
  FBiosLabel.SetBounds(20, TITLE_BAR_H + 88, 50, 20);
  FBiosLabel.Caption := 'BIOS:';
  FBiosLabel.Font.Color := COLOR_FG_MID;
  FBiosLabel.Transparent := True;

  FBiosEdit := TEdit.Create(Self);
  FBiosEdit.Parent := Self;
  FBiosEdit.SetBounds(70, TITLE_BAR_H + 84, 350, 26);
  FBiosEdit.Text := ResolveDefaultBios;
  FBiosEdit.Color := COLOR_BG_BTN;
  FBiosEdit.Font.Color := COLOR_FG;
  FBiosEdit.Font.Size := 9;
  FBiosEdit.BorderStyle := bsSingle;
  FBiosEdit.ParentColor := False;
  FBiosEdit.ParentFont := False;

  FBiosBrowse := TButton.Create(Self);
  FBiosBrowse.Parent := Self;
  FBiosBrowse.SetBounds(425, TITLE_BAR_H + 84, 95, 26);
  FBiosBrowse.Caption := 'Browse…';
  FBiosBrowse.OnClick := @OnBiosBrowseClick;

  FOpenButton := TButton.Create(Self);
  FOpenButton.Parent := Self;
  FOpenButton.SetBounds(20, TITLE_BAR_H + 130, 500, 40);
  FOpenButton.Caption := 'Open ROM…';
  FOpenButton.Font.Size := 11;
  FOpenButton.Font.Style := [fsBold];
  FOpenButton.OnClick := @OnOpenClick;

  FRecentLabel := TLabel.Create(Self);
  FRecentLabel.Parent := Self;
  FRecentLabel.SetBounds(20, TITLE_BAR_H + 188, 500, 20);
  FRecentLabel.Caption := 'Recent ROMs (double-click to launch):';
  FRecentLabel.Font.Color := COLOR_FG_MID;
  FRecentLabel.Transparent := True;

  FRecentList := TListBox.Create(Self);
  FRecentList.Parent := Self;
  FRecentList.SetBounds(20, TITLE_BAR_H + 214, 500, 168);
  FRecentList.Color := COLOR_BG_PANEL;
  FRecentList.Font.Color := COLOR_FG;
  FRecentList.Font.Name := 'Consolas';
  FRecentList.Font.Size := 9;
  FRecentList.BorderStyle := bsSingle;
  FRecentList.ParentColor := False;
  FRecentList.ParentFont := False;
  FRecentList.OnDblClick := @OnRecentDblClick;

  { Controls reference — informational, always visible so the player
    can glance at it while playing. Displays the default mapping from
    input.pas. }
  FControlsHeader := TLabel.Create(Self);
  FControlsHeader.Parent := Self;
  FControlsHeader.SetBounds(20, TITLE_BAR_H + 392, 500, 20);
  FControlsHeader.Caption := 'GBA controls (default mapping):';
  FControlsHeader.Font.Color := COLOR_FG_MID;
  FControlsHeader.Transparent := True;

  FControlsView := TMemo.Create(Self);
  FControlsView.Parent := Self;
  FControlsView.SetBounds(20, TITLE_BAR_H + 418, 500, 142);
  FControlsView.ReadOnly := True;
  FControlsView.TabStop := False;
  FControlsView.Color := COLOR_BG_PANEL;
  FControlsView.Font.Color := COLOR_FG;
  FControlsView.Font.Name := 'Consolas';
  FControlsView.Font.Size := 9;
  FControlsView.BorderStyle := bsSingle;
  FControlsView.ParentColor := False;
  FControlsView.ParentFont := False;
  FControlsView.ScrollBars := ssNone;
  FControlsView.Lines.Text :=
    '  A       : Z                  L         : Q'           + LineEnding +
    '  B       : X                  R         : W'           + LineEnding +
    '  Start   : Enter              Up        : Arrow Up'    + LineEnding +
    '  Select  : Backspace          Down      : Arrow Down'  + LineEnding +
    '                               Left      : Arrow Left'  + LineEnding +
    '                               Right     : Arrow Right' + LineEnding +
    ''                                                       + LineEnding +
    '  Esc closes the emulator window.';

  FQuitButton := TButton.Create(Self);
  FQuitButton.Parent := Self;
  FQuitButton.SetBounds(440, TITLE_BAR_H + 570, 80, 32);
  FQuitButton.Caption := 'Quit';
  FQuitButton.OnClick := @OnQuitClick;
end;

{ ───── Title-bar interactions ─────────────────────────────────────── }

procedure TGbaShellForm.TitleBarMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  { Hand off drag to Windows — gives us Aero Snap, edge-snap, snap
    layouts on Win11 etc. for free. ReleaseCapture is the prerequisite:
    Lazarus has the mouse, the OS won't take over until we release. }
  ReleaseCapture;
  SendMessage(Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
end;

procedure TGbaShellForm.TitleBarDblClick(Sender: TObject);
begin
  if WindowState = wsMaximized then WindowState := wsNormal
                               else WindowState := wsMaximized;
end;

{ ───── Form-edge resize ───────────────────────────────────────────── }

procedure TGbaShellForm.FormMouseMoveHandler(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
var
  atL, atR, atT, atB: Boolean;
begin
  if WindowState = wsMaximized then
  begin
    Cursor := crDefault;
    Exit;
  end;
  atL := X < RESIZE_BORDER;
  atR := X > Width  - RESIZE_BORDER;
  atT := Y < RESIZE_BORDER;
  atB := Y > Height - RESIZE_BORDER;
  if (atL and atT) or (atR and atB) then Cursor := crSizeNWSE
  else if (atR and atT) or (atL and atB) then Cursor := crSizeNESW
  else if atL or atR then Cursor := crSizeWE
  else if atT or atB then Cursor := crSizeNS
  else Cursor := crDefault;
end;

procedure TGbaShellForm.FormMouseDownHandler(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
const
  HTLEFT = 10; HTRIGHT = 11; HTTOP = 12; HTTOPLEFT = 13; HTTOPRIGHT = 14;
  HTBOTTOM = 15; HTBOTTOMLEFT = 16; HTBOTTOMRIGHT = 17;
var
  direction: Integer;
  atL, atR, atT, atB: Boolean;
begin
  if (Button <> mbLeft) or (WindowState = wsMaximized) then Exit;
  atL := X < RESIZE_BORDER;
  atR := X > Width  - RESIZE_BORDER;
  atT := Y < RESIZE_BORDER;
  atB := Y > Height - RESIZE_BORDER;
  if      atL and atT then direction := HTTOPLEFT
  else if atR and atT then direction := HTTOPRIGHT
  else if atL and atB then direction := HTBOTTOMLEFT
  else if atR and atB then direction := HTBOTTOMRIGHT
  else if atL then direction := HTLEFT
  else if atR then direction := HTRIGHT
  else if atT then direction := HTTOP
  else if atB then direction := HTBOTTOM
  else Exit;
  ReleaseCapture;
  SendMessage(Handle, WM_NCLBUTTONDOWN, direction, 0);
end;

{ ───── Window-button hover + click ────────────────────────────────── }

procedure TGbaShellForm.BtnMinClick(Sender: TObject);
begin
  WindowState := wsMinimized;
end;

procedure TGbaShellForm.BtnMaxClick(Sender: TObject);
begin
  if WindowState = wsMaximized then WindowState := wsNormal
                               else WindowState := wsMaximized;
end;

procedure TGbaShellForm.BtnCloseClick(Sender: TObject);
begin
  Close;
end;

procedure TGbaShellForm.BtnMinEnter(Sender: TObject);
begin
  FBtnMinHover := True;
  FBtnMin.Invalidate;
end;

procedure TGbaShellForm.BtnMinLeave(Sender: TObject);
begin
  FBtnMinHover := False;
  FBtnMin.Invalidate;
end;

procedure TGbaShellForm.BtnMaxEnter(Sender: TObject);
begin
  FBtnMaxHover := True;
  FBtnMax.Invalidate;
end;

procedure TGbaShellForm.BtnMaxLeave(Sender: TObject);
begin
  FBtnMaxHover := False;
  FBtnMax.Invalidate;
end;

procedure TGbaShellForm.BtnCloseEnter(Sender: TObject);
begin
  FBtnCloseHover := True;
  FBtnClose.Invalidate;
end;

procedure TGbaShellForm.BtnCloseLeave(Sender: TObject);
begin
  FBtnCloseHover := False;
  FBtnClose.Invalidate;
end;

procedure TGbaShellForm.PaintChromeButton(Sender: TObject);
{ Shared paint handler for the three chrome buttons. Identifies which
  button via Sender = FBtnMin/Max/Close, fills background based on
  hover state, then draws the icon (horizontal line / outlined square /
  X) via GDI primitives matching the emulator window's chrome
  exactly. }
var
  pb: TPaintBox;
  cx, cy: Integer;
  isClose, isHovered: Boolean;
begin
  pb := Sender as TPaintBox;
  isClose := (pb = FBtnClose);

  if pb = FBtnMin then       isHovered := FBtnMinHover
  else if pb = FBtnMax then  isHovered := FBtnMaxHover
  else if pb = FBtnClose then isHovered := FBtnCloseHover
  else                       isHovered := False;

  { Background. }
  if isHovered then
  begin
    if isClose then pb.Canvas.Brush.Color := COLOR_DANGER
               else pb.Canvas.Brush.Color := COLOR_BG_HOVER;
  end
  else
    pb.Canvas.Brush.Color := COLOR_BG_TITLE;
  pb.Canvas.FillRect(pb.ClientRect);

  { Pen for icon strokes. }
  if isHovered then pb.Canvas.Pen.Color := COLOR_FG
               else pb.Canvas.Pen.Color := COLOR_FG_MID;
  pb.Canvas.Pen.Width := 1;

  cx := pb.Width  div 2;
  cy := pb.Height div 2;

  if pb = FBtnMin then
  begin
    pb.Canvas.MoveTo(cx - 5, cy);
    pb.Canvas.LineTo(cx + 6, cy);
  end
  else if pb = FBtnMax then
  begin
    pb.Canvas.MoveTo(cx - 5, cy - 5);
    pb.Canvas.LineTo(cx + 5, cy - 5);
    pb.Canvas.LineTo(cx + 5, cy + 5);
    pb.Canvas.LineTo(cx - 5, cy + 5);
    pb.Canvas.LineTo(cx - 5, cy - 5);
  end
  else if pb = FBtnClose then
  begin
    pb.Canvas.MoveTo(cx - 5, cy - 5);
    pb.Canvas.LineTo(cx + 6, cy + 6);
    pb.Canvas.MoveTo(cx + 5, cy - 5);
    pb.Canvas.LineTo(cx - 6, cy + 6);
  end;
end;

{ ───── Recent ROMs ────────────────────────────────────────────────── }

function TGbaShellForm.ResolveDefaultBios: string;
var
  candidate: string;
  exeDir: string;
begin
  exeDir := ExtractFilePath(ParamStr(0));

  candidate := IncludeTrailingPathDelimiter(GetCurrentDir) + DEFAULT_BIOS;
  if FileExists(candidate) then Exit(ExpandFileName(candidate));

  candidate := exeDir + DEFAULT_BIOS;
  if FileExists(candidate) then Exit(ExpandFileName(candidate));

  candidate := exeDir + '..\' + DEFAULT_BIOS;
  if FileExists(candidate) then Exit(ExpandFileName(candidate));

  Result := ExpandFileName(exeDir + '..\' + DEFAULT_BIOS);
end;

function TGbaShellForm.ResolveDefaultRomDir: string;
var
  candidate: string;
  exeDir: string;
begin
  exeDir := ExtractFilePath(ParamStr(0));

  candidate := IncludeTrailingPathDelimiter(GetCurrentDir) + 'roms';
  if DirectoryExists(candidate) then Exit(ExpandFileName(candidate));

  candidate := exeDir + 'roms';
  if DirectoryExists(candidate) then Exit(ExpandFileName(candidate));

  candidate := exeDir + '..\roms';
  if DirectoryExists(candidate) then Exit(ExpandFileName(candidate));

  Result := '';
end;

function TGbaShellForm.RecentPath: string;
var
  appData, dir: string;
begin
  appData := SysUtils.GetEnvironmentVariable('APPDATA');
  if appData = '' then appData := GetCurrentDir;
  dir := IncludeTrailingPathDelimiter(appData) + RECENT_DIR;
  if not DirectoryExists(dir) then ForceDirectories(dir);
  Result := IncludeTrailingPathDelimiter(dir) + RECENT_FILE;
end;

procedure TGbaShellForm.LoadRecent;
var
  p: string;
begin
  FRecent.Clear;
  p := RecentPath;
  if FileExists(p) then
    try
      FRecent.LoadFromFile(p);
    except
      { ignore corrupt file — start empty }
    end;
end;

procedure TGbaShellForm.SaveRecent;
var
  p: string;
begin
  p := RecentPath;
  try
    FRecent.SaveToFile(p);
  except
    { recent list is a convenience, not load-bearing }
  end;
end;

procedure TGbaShellForm.AddRecent(const romPath: string);
var
  idx: Integer;
begin
  idx := FRecent.IndexOf(romPath);
  if idx >= 0 then FRecent.Delete(idx);
  FRecent.Insert(0, romPath);
  while FRecent.Count > RECENT_MAX do FRecent.Delete(FRecent.Count - 1);
  SaveRecent;
  RefreshRecentList;
end;

procedure TGbaShellForm.RefreshRecentList;
var
  i: Integer;
begin
  FRecentList.Items.BeginUpdate;
  try
    FRecentList.Items.Clear;
    for i := 0 to FRecent.Count - 1 do
      FRecentList.Items.Add(FRecent[i]);
  finally
    FRecentList.Items.EndUpdate;
  end;
end;

{ ───── Body interactions ──────────────────────────────────────────── }

procedure TGbaShellForm.OnOpenClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title  := 'Select GBA ROM';
    dlg.Filter := 'GBA ROMs (*.gba)|*.gba|All files (*.*)|*.*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if ResolveDefaultRomDir <> '' then dlg.InitialDir := ResolveDefaultRomDir;
    if dlg.Execute then
      LaunchEmulator(dlg.FileName);
  finally
    dlg.Free;
  end;
end;

procedure TGbaShellForm.OnBiosBrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title  := 'Select GBA BIOS';
    dlg.Filter := 'BIOS image (*.bin)|*.bin|All files (*.*)|*.*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if dlg.Execute then FBiosEdit.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

procedure TGbaShellForm.OnQuitClick(Sender: TObject);
begin
  Close;
end;

procedure TGbaShellForm.OnRecentDblClick(Sender: TObject);
var
  selected: string;
begin
  if FRecentList.ItemIndex < 0 then Exit;
  selected := FRecentList.Items[FRecentList.ItemIndex];
  if not FileExists(selected) then
  begin
    SetStatus('Selected ROM no longer exists; removed from recent list.');
    FRecent.Delete(FRecentList.ItemIndex);
    SaveRecent;
    RefreshRecentList;
    Exit;
  end;
  LaunchEmulator(selected);
end;

procedure TGbaShellForm.LaunchEmulator(const romPath: string);
var
  opts: TGbaRunOptions;
  biosPath: string;
begin
  biosPath := Trim(FBiosEdit.Text);
  if biosPath = '' then biosPath := DEFAULT_BIOS;
  if not FileExists(biosPath) then
  begin
    MessageDlg('BIOS not found',
      Format('BIOS image not found at "%s". The repository bundles one at bios\gba_bios.bin (16 KB) - run from the repository root or browse to it.',
             [biosPath]),
      mtError, [mbOK], 0);
    Exit;
  end;
  if not FileExists(romPath) then
  begin
    MessageDlg('ROM not found', Format('ROM file not found: %s', [romPath]),
      mtError, [mbOK], 0);
    Exit;
  end;

  opts := DefaultRunOptions;
  opts.RomPath      := romPath;
  opts.BiosPath     := biosPath;
  opts.WindowTitle  := APP_TITLE + ' - ' + ExtractFileName(romPath);
  opts.Verbose      := False;
  opts.PrintSummary := False;
  opts.MaxFrames    := 0;

  SetStatus(Format('Running %s…', [ExtractFileName(romPath)]));
  Application.ProcessMessages;

  { Don't Hide the launcher — it stays visible alongside the emulator
    window so the controls reference panel can be glanced at while
    playing. RunGba blocks on its own message pump; the launcher will
    be visually frozen (no clicks dispatch) for the duration, but its
    CONTENT (especially the controls panel) is fully visible. }
  try
    RunGba(opts);
    AddRecent(romPath);
  finally
    BringToFront;
  end;
  SetStatus(Format('Last run: %s', [ExtractFileName(romPath)]));
end;

procedure TGbaShellForm.SetStatus(const msg: string);
begin
  FStatusLabel.Caption := msg;
end;

procedure TGbaShellForm.FormCloseHandler(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  Application.Terminate;
end;

end.
