@echo off
REM ===========================================================================
REM run.bat — boot dos.img in QEMU (real-mode x86)
REM Uses the locally installed QEMU at C:\qemu. Falls back to PATH if absent.
REM Also works with Bochs:  bochs -q -f bochsrc.txt
REM ===========================================================================
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%dos.img" (
  echo dos.img not found, run build.bat first
  exit /b 1
)
set "QEMU=qemu-system-i386.exe"
if exist "C:\qemu\qemu-system-i386.exe" set "QEMU=C:\qemu\qemu-system-i386.exe"
"%QEMU%" -fda "%ROOT%dos.img" -boot a -m 16 -rtc base=localtime -nographic
