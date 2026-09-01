@echo off
REM ===========================================================================
REM win9x/run.bat — Boot win9x.img in QEMU
REM ===========================================================================
setlocal
set "ROOT=%~dp0"
if not exist "%ROOT%win9x.img" (
  echo win9x.img not found, run build.bat first
  exit /b 1
)
set "QEMU=qemu-system-i386.exe"
if exist "C:\qemu\qemu-system-i386.exe" set "QEMU=C:\qemu\qemu-system-i386.exe"
"%QEMU%" -fda "%ROOT%win9x.img" -boot a -m 32 -rtc base=localtime -nographic -debugcon file:"%ROOT%dbg.log"
