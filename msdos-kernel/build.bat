@echo off
REM ===========================================================================
REM build.bat — assemble the MS-DOS toy kernel and pack a 1.44MB boot image
REM Requires: NASM (https://nasm.us) on PATH
REM ===========================================================================
setlocal
set "ROOT=%~dp0"
set "SRC=%ROOT%src"
set "OUT=%ROOT%build"

REM locate nasm (prefer a few well-known install locations)
set "NASM=nasm.exe"
if exist "C:\mingw64\mingw64\bin\nasm.exe" set "NASM=C:\mingw64\mingw64\bin\nasm.exe"
if exist "C:\nasm\nasm.exe" set "NASM=C:\nasm\nasm.exe"

if not exist "%OUT%" mkdir "%OUT%"

echo [1/3] assembling bootloader ...
"%NASM%" -f bin "%SRC%\boot.asm" -o "%OUT%\boot.bin" || goto :fail
echo [2/3] assembling kernel ...
"%NASM%" -f bin "%SRC%\kernel.asm" -o "%OUT%\kernel.bin" || goto :fail

echo [3/3] packing dos.img (1.44MB floppy) ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%pack.ps1" -OutDir "%OUT%" -RootDir "%ROOT%" || goto :fail

echo BUILD OK
goto :eof

:fail
echo BUILD FAILED
exit /b 1
