@echo off
setlocal
set ROOT=%~dp0
set PRJ=%ROOT%..\..
set SRC=%ROOT%
set OUT=%ROOT%build
set NASM=C:\mingw64\mingw64\bin\nasm.exe

if not exist "%OUT%" mkdir "%OUT%"

echo [1/3] Assembling boot32...
"%NASM%" -f bin -DVIDEO_MODE=0x0013 -I "%PRJ%\" "%SRC%boot32.asm" -o "%OUT%\boot32.bin"

echo [2/3] Assembling kernel32 (NET_TEST)...
"%NASM%" -f bin -w-label-redef-late -DNET_TEST -I "%PRJ%\" "%SRC%a4_gui.asm" -o "%OUT%\kernel32.bin"

echo [3/3] Packing winme_test.img...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PRJ%\common\pack32.ps1" -Boot "%OUT%\boot32.bin" -Kernel "%OUT%\kernel32.bin" -OutImage "%ROOT%winme_test.img"

echo.
echo Build complete: winme_test.img
echo Run: verify_test.ps1
