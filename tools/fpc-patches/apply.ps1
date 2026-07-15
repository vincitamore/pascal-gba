# Apply the three local FPC GBA RTL patches.  Idempotent: each
# patch is guarded by a marker string so re-running is a no-op.
#
# Bugs fixed:
#   1. sysheap.inc -- SysOSAlloc returned same pointer every call
#   2. system.pp   -- missing {$linklib c} / {$linklib gcc}
#   3. prt0.as     -- didn't call __libc_init_array before main

$ErrorActionPreference = 'Stop'
$fpcsrc = 'C:\fpcupdeluxe\fpcsrc\rtl\gba'
if (-not (Test-Path $fpcsrc)) {
  Write-Host "FPC source not at $fpcsrc -- run install-tgba.ps1 first"
  exit 1
}

function Apply-Patch {
  param([string]$Target, [string]$Marker, [scriptblock]$EditScript)
  $body = Get-Content $Target -Raw
  if ($body -match [regex]::Escape($Marker)) {
    Write-Host "  [skip] $Target already patched (marker: '$Marker')"
    return
  }
  & $EditScript $Target
  Write-Host "  [done] $Target patched"
}

# Patch 1: sysheap.inc
Apply-Patch -Target "$fpcsrc\sysheap.inc" `
  -Marker 'heap_ptr:' `
  -EditScript {
    param($p)
    $body = Get-Content $p -Raw
    $body = $body -replace `
      'var\r?\n  heap_start: longint; external name ''__eheap_start'';\r?\n\r?\nfunction SysOSAlloc\(size: ptruint\): pointer;\r?\nbegin\r?\n  result := @heap_start;\r?\nend;', `
      @'
var
  heap_start: longint;  external name '__eheap_start';
  heap_end:   longint;  external name '__eheap_end';
  heap_ptr:   PtrUInt = 0;

function SysOSAlloc(size: ptruint): pointer;
{ Linear bump allocator across the EWRAM heap region the linker
  reserves at __eheap_start .. __eheap_end (typically ~250 KB).
  Pre-2026 returned @heap_start each call; overwrote on every
  subsequent call. }
begin
  if heap_ptr = 0 then
    heap_ptr := PtrUInt(@heap_start);
  size := (size + 3) and not PtrUInt(3);
  if (heap_ptr + size) > PtrUInt(@heap_end) then
    Exit(nil);
  Result := pointer(heap_ptr);
  heap_ptr := heap_ptr + size;
end;
'@
    [System.IO.File]::WriteAllText($p, $body, [System.Text.UTF8Encoding]::new($false))
  }

# Patch 2: system.pp -- expand {$linklib sysbase} to four linklibs
Apply-Patch -Target "$fpcsrc\system.pp" `
  -Marker '{$linklib gba}' `
  -EditScript {
    param($p)
    $body = Get-Content $p -Raw
    $body = $body -replace `
      '\{\$linklib sysbase\}', `
      @'
{$linklib c}        { devkitARM newlib: __libc_init_array, heap, libgloss }
{$linklib sysbase}  { devkitARM glue: heap symbols, syscall stubs }
{$linklib gba}      { devkitARM libgba: GBA-specific runtime init }
{$linklib gcc}      { compiler runtime: 64-bit div, soft-float helpers }
'@
    [System.IO.File]::WriteAllText($p, $body, [System.Text.UTF8Encoding]::new($false))
  }

# Patch 3: prt0.as -- add __libc_init_array call before main jump
Apply-Patch -Target "$fpcsrc\prt0.as" `
  -Marker '__libc_init_array' `
  -EditScript {
    param($p)
    $body = Get-Content $p -Raw
    $insert = @"
@---------------------------------------------------------------------------------
@ Run static initializers + initialise newlib's heap (libc_init_array)
@---------------------------------------------------------------------------------
	ldr	r3,=__libc_init_array
	bl	_blx_r3_stub
"@
    # Find the line "@ Jump to user code" and insert before it
    $body = $body -replace `
      "(?ms)(\r?\n)(\@-+\r?\n\@ Jump to user code\r?\n)", `
      "`$1$insert`$1`$2"
    [System.IO.File]::WriteAllText($p, $body, [System.Text.UTF8Encoding]::new($false))
  }

Write-Host ''
Write-Host '=== patches applied ==='
Write-Host 'Now rebuild the GBA RTL: tools\build-gba-rtl.ps1'
