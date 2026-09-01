@echo off
REM ===========================================================================
REM win9x/build.bat — Dispatcher for the Win9x axis.
REM   The axis sources are now organized by generation under win9x/win95,
REM   win9x/win98, win9x/winme. The default (legacy) build is the M-A1
REM   Win95 generation, which also stages the legacy win9x/win9x.img used by
REM   the full-line _qemu_test.ps1 (Axis A).
REM ===========================================================================
call "%~dp0win95\build.bat"
