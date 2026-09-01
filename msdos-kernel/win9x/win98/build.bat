@echo off
REM ===========================================================================
REM win98/build.bat — Build the Win98 generation (M-A3: VMM/VxD era)
REM   Still boots through the M0 real-mode bootloader (Win98 retained a
REM   real-mode boot path). Sources live in this win98/ subdir.
REM   Produces win98/win98.img.
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

echo [1/4] assembling M0 bootloader (real-mode)...
"%NASM%" -f bin "%ROOT%boot.asm" -o "%OUT%\boot.bin" || goto :fail

echo [2/4] assembling M-A3 kernel (VMM/VxD)...
"%NASM%" -f bin -I "%PRJ%\\" "%SRC%a3_vmm.asm" -o "%OUT%\kernel.bin" || goto :fail

echo [3/4] packing dos.img (1.44MB floppy)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PRJ%\pack.ps1" -OutDir "%OUT%" -RootDir "%PARENT%" || goto :fail

echo [4/4] staging image -> win98.img...
if exist "%PRJ%\dos.img" move /Y "%PRJ%\dos.img" "%ROOT%win98.img" >nul

echo BUILD OK — win98/win98.img
goto :eof

:fail
echo BUILD FAILED
exit /b 1
