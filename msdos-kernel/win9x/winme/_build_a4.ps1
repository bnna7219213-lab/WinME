$ErrorActionPreference = 'Stop'
$NASM = 'C:\mingw64\mingw64\bin\nasm.exe'
$ROOT = 'c:\Users\bnna7\workspace\msdos-kernel\win9x\winme'
$PRJ  = 'c:\Users\bnna7\workspace\msdos-kernel'
$OUT  = Join-Path $ROOT 'build'
if (-not (Test-Path $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

Write-Host "[1/2] assembling a4_gui.asm ..."
& $NASM '-f' 'bin' '-w-label-redef-late' '-I' ($PRJ + '\') ($ROOT + '\a4_gui.asm') '-o' ($OUT + '\kernel32.bin')
if ($LASTEXITCODE -ne 0) { Write-Host "NASM FAILED (a4_gui) exit=$LASTEXITCODE"; exit 1 }
$ks = (Get-Item ($OUT + '\kernel32.bin')).Length
Write-Host ("kernel32.bin = {0} bytes" -f $ks)

Write-Host "[2/2] packing winme.img ..."
& 'powershell.exe' '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' ($PRJ + '\common\pack32.ps1') '-Boot' ($OUT + '\boot32.bin') '-Kernel' ($OUT + '\kernel32.bin') '-OutImage' ($ROOT + '\winme.img')
if ($LASTEXITCODE -ne 0) { Write-Host "PACK FAILED exit=$LASTEXITCODE"; exit 1 }
Write-Host "BUILD OK"
