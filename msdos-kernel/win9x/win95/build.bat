@echo off
REM ===========================================================================
REM win95/build.bat — Build the Win95 generation (M-A1: PM switch + DPMI era)
REM   Faithful to Win95: still boots through the M0 real-mode bootloader and a
REM   real-mode->protected-mode kernel. Sources live in this win95/ subdir.
REM   Produces both the legacy win9x/win9x.img (consumed by the full-line
REM   _qemu_test.ps1 Axis A) and win95/win95.img.
REM ===========================================================================
setlocal
set "ROOT=%~dp0"
for %%I in ("%ROOT%..\..") do set "PRJ=%%~fI"
set "PARENT=%PRJ%\win9x"
set "SRC=%ROOT%"
set "OUT=%PARENT%\build"
set "NASM=nasm.exe"
if exist "C:\mingw64\mingw64\bin\nasm.exe" set "NASM=C:\mingw64\mingw64\bin\nasm.exe"

if not exist "%OUT%" mkdir "%OUT%"

echo [1/4] assembling M0 bootloader (real-mode)...
"%NASM%" -f bin "%ROOT%boot.asm" -o "%OUT%\boot.bin" || goto :fail

echo [2/4] assembling M-A1 kernel (A1+A2, real-mode->PM)...
"%NASM%" -f bin -I "%PRJ%\\" "%SRC%a1_kernel_pm.asm" -o "%OUT%\kernel.bin" || goto :fail

echo [3/4] packing dos.img (1.44MB floppy)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PRJ%\pack.ps1" -OutDir "%OUT%" -RootDir "%PARENT%" || goto :fail

echo [4/4] staging images...
if exist "%PRJ%\dos.img" move /Y "%PRJ%\dos.img" "%PARENT%\win9x.img" >nul
if exist "%PARENT%\win9x.img" copy /Y "%PARENT%\win9x.img" "%ROOT%win95.img" >nul

echo BUILD OK — win95/win95.img (and legacy win9x/win9x.img)
goto :eof

:fail
echo BUILD FAILED
exit /b 1
