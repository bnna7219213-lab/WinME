@echo off
REM ===========================================================================
REM winme/build.bat — Build the WinMe generation (M-A4: GUI 雏形)
REM   WinMe eliminated real-mode DOS: there is NO M0 16-bit bootloader here.
REM   The system boots straight into 32-bit protected mode via the 32-bit
REM   boot32 loader (boot32.asm, -DVIDEO_MODE=0x0013) and runs a flat 32-bit
REM   kernel (a4_gui.asm, BITS32 ORG 0x100000). This is the "real-mode boot
REM   path removed" requirement. Sources live in this winme/ subdir.
REM   Produces winme/winme.img.
REM ===========================================================================
setlocal
set "ROOT=%~dp0"
for %%I in ("%ROOT%..\..") do set "PRJ=%%~fI"
set "PARENT=%PRJ%\win9x"
set "SRC=%ROOT%"
set "OUT=%ROOT%build"
set "NASM=nasm.exe"
if exist "C:\mingw64\mingw64\bin\nasm.exe" set "NASM=C:\mingw64\mingw64\bin\nasm.exe"

if not exist "%OUT%" mkdir "%OUT%"

echo [1/3] assembling 32-bit loader (boot32, VIDEO_MODE=0x0013)...
"%NASM%" -f bin -DVIDEO_MODE=0x0013 -I "%PRJ%" "%SRC%boot32.asm" -o "%OUT%\boot32.bin" || goto :fail

echo [2/3] assembling M-A4 GUI kernel (32-bit, real-mode-free)...
"%NASM%" -f bin -w-label-redef-late -I "%PRJ%" "%SRC%a4_gui.asm" -o "%OUT%\kernel32.bin" || goto :fail

echo [3/3] packing winme.img (1.44MB floppy)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PRJ%\common\pack32.ps1" -Boot "%OUT%\boot32.bin" -Kernel "%OUT%\kernel32.bin" -OutImage "%ROOT%winme.img" || goto :fail

echo BUILD OK — winme/winme.img
goto :eof

:fail
echo BUILD FAILED
exit /b 1
