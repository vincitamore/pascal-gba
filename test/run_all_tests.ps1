# Run every unit test in test/ that has a built binary in bin/.
# Reports pass/fail summary per test executable. Surfaces non-zero
# exit codes for tests that fail beyond just printing a summary line.
#
# Run from repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\run_all_tests.ps1
#
# Expected baseline:
#   phase_b: 38  phase_d: 23  phase_e: 40  phase_f: 50
#   armcore: 81  ppu: 17  bios_hle: 30  save: 10
#   replay: 31   dbglog: 23
# Total: 335 cases + 4163 save-assertions.

foreach ($t in @('test_phase_b','test_phase_d','test_phase_e','test_phase_f','test_armcore','test_ppu','test_bios_hle','test_save','test_replay','test_dbglog','test_kit')) {
  Write-Host "--- $t ---"
  $out = & "bin\$t.exe" 2>&1
  $out | Select-String -Pattern 'passed|FAIL|===|all\s+tests' | Select-Object -Last 5
  if ($LASTEXITCODE -ne 0) { Write-Host "  ! non-zero exit: $LASTEXITCODE" }
}
