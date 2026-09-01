# Streaming runner for _test_a4.ps1
# The execute_command harness only flushes output at process exit, which trips
# the idle-timeout on long QEMU runs. This runner launches the test, merges the
# Information (Write-Host) stream into stdout, and prints lines as they arrive.
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$psi  = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "powershell.exe"
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$($root)\_test_a4.ps1' 6>&1`""
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)
$sw = $p.StandardOutput
$er = $p.StandardError

$deadline = (Get-Date).AddSeconds(120)
while (-not $p.HasExited) {
    while (-not $sw.EndOfStream) { Write-Host $sw.ReadLine() }
    while (-not $er.EndOfStream) { Write-Host ("ERR: " + $er.ReadLine()) }
    if ((Get-Date) -gt $deadline) { Write-Host "[runner] TIMEOUT - killing"; $p.Kill(); break }
    Write-Host "." -NoNewline
    Start-Sleep -Milliseconds 500
}
while (-not $sw.EndOfStream) { Write-Host $sw.ReadLine() }
while (-not $er.EndOfStream) { Write-Host ("ERR: " + $er.ReadLine()) }
Write-Host ""
Write-Host "[runner] test exited with code $($p.ExitCode)"
