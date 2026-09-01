# _build_all.ps1 — Assemble all P0 + axis source files
$nas  = 'C:\mingw64\mingw64\bin\nasm.exe'
$root = 'C:\Users\bnna7\workspace\msdos-kernel'

# Create build dirs
$dirs = @(
    "$root\common\build",
    "$root\win9x\build",
    "$root\winnt\build",
    "$root\win2k\build",
    "$root\winxp\build"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$results = @()

# 1. common/boot32.asm
Write-Host "=== [1/6] common/boot32.asm ===" -ForegroundColor Cyan
$out = "$root\common\build\boot32.bin"
& $nas -f bin "-I$root\" "$root\common\boot32.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "boot32.asm: exit=$LASTEXITCODE size=${sz}B"

# 2. win9x a1_kernel_pm.asm
Write-Host "`n=== [2/6] win9x/src/a1_kernel_pm.asm ===" -ForegroundColor Cyan
$out = "$root\win9x\build\kernel.bin"
& $nas -f bin "-I$root\" "$root\win9x\src\a1_kernel_pm.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "a1_kernel_pm.asm: exit=$LASTEXITCODE size=${sz}B"

# 3. winnt b1_kernel32.asm
Write-Host "`n=== [3/6] winnt/src/b1_kernel32.asm ===" -ForegroundColor Cyan
$out = "$root\winnt\build\kernel32.bin"
& $nas -f bin "-I$root\" "$root\winnt\src\b1_kernel32.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "b1_kernel32.asm: exit=$LASTEXITCODE size=${sz}B"

# 4. win2k c1_version.asm
Write-Host "`n=== [4/6] win2k/src/c1_version.asm ===" -ForegroundColor Cyan
$out = "$root\win2k\build\kernel32.bin"
& $nas -f bin "-I$root\" "$root\win2k\src\c1_version.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "c1_version.asm: exit=$LASTEXITCODE size=${sz}B"

# 5. winxp d1_nt51.asm
Write-Host "`n=== [5/6] winxp/src/d1_nt51.asm ===" -ForegroundColor Cyan
$out = "$root\winxp\build\kernel32.bin"
& $nas -f bin "-I$root\" "$root\winxp\src\d1_nt51.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "d1_nt51.asm: exit=$LASTEXITCODE size=${sz}B"

# 6. M0 boot.asm (for win9x reuse)
Write-Host "`n=== [6/6] src/boot.asm (M0, for win9x) ===" -ForegroundColor Cyan
$out = "$root\win9x\build\boot.bin"
& $nas -f bin "$root\src\boot.asm" -o $out 2>&1
$sz = if (Test-Path $out) { (Get-Item $out).Length } else { 0 }
Write-Host "exit=$LASTEXITCODE size=${sz}B"
$results += "boot.asm(M0): exit=$LASTEXITCODE size=${sz}B"

# Summary
Write-Host "`n===== SUMMARY =====" -ForegroundColor Yellow
foreach ($r in $results) { Write-Host "  $r" }
$allOk = ($results | Where-Object { $_ -match 'exit=0' }).Count -eq 6
if ($allOk) {
    Write-Host "`n[ALL PASS] 6/6 files assembled successfully." -ForegroundColor Green
} else {
    Write-Host "`n[FAIL] Some files failed." -ForegroundColor Red
}
