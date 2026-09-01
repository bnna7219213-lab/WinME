# Start serve_a4.py, wait 1s, curl test, then kill
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$serveLog = "$root\win9x\winme\_serve_a4.log"
$serveLogErr = "$root\win9x\winme\_serve_a4.err"
Remove-Item $serveLog, $serveLogErr -Force -ErrorAction SilentlyContinue
$s = Start-Process -FilePath "python" -ArgumentList "$root\win9x\winme\serve_a4.py" `
    -PassThru -NoNewWindow -RedirectStandardOutput $serveLog -RedirectStandardError $serveLogErr
Start-Sleep -Milliseconds 1000
try {
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:8081/a4.exe" -UseBasicParsing
    Write-Output "HTTP $resp.StatusCode, ContentLength=$($resp.Content.Length)"
} catch {
    Write-Output "CURL FAIL: $_"
}
Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue
Write-Output "--- server log ---"
Get-Content $serveLog -ErrorAction SilentlyContinue
Write-Output "--- server stderr ---"
Get-Content $serveLogErr -ErrorAction SilentlyContinue