# run_net_test.ps1 — Real RTL8139 network test (no GDB injection)
#
# Flow:
#   1. Start Python HTTP server (serve_a4.py) on port 8080 serving real PE32
#   2. Launch QEMU with RTL8139 NIC + user-mode networking
#   3. Kernel does ARP → TCP handshake → HTTP GET → receives PE → pe_parse → exe_load → exe_run
#   4. Check debug log for PE download + execution markers
#
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\winme\winme_net.img"
$dbg  = "$root\win9x\winme\_net_test.log"
$ppm  = "$root\win9x\winme\_net_test.ppm"
$mon  = 4512
$py   = "python"

function ReadShared($path){
    if(-not(Test-Path $path)){return ""}
    try{
        $fs=New-Object System.IO.FileStream($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr=New-Object System.IO.StreamReader($fs)
        $t=$sr.ReadToEnd(); $sr.Close();$fs.Close(); return $t
    }catch{return ""}
}

# --- Cleanup ---
Remove-Item $dbg,$ppm -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process python* -ErrorAction SilentlyContinue | Where-Object {$_.CommandLine -like '*serve_a4*'} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

# --- Start Python HTTP server on port 8080 ---
Write-Output "[net_test] Starting Python HTTP server on port 8080..."
$pyProc = Start-Process -FilePath $py -ArgumentList "-u","$root\win9x\winme\serve_a4.py" -PassThru -NoNewWindow -RedirectStandardOutput "$root\win9x\winme\_serve_a4.log" -RedirectStandardError "$root\win9x\winme\_serve_a4.err"
Start-Sleep -Milliseconds 800

if($pyProc.HasExited){
    Write-Output "[FAIL] Python HTTP server failed to start"
    exit 1
}
Write-Output "[net_test] HTTP server running (PID=$($pyProc.Id))"

# --- Launch QEMU with RTL8139 + user-mode networking ---
Write-Output "[net_test] Launching QEMU with RTL8139..."
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot","-no-shutdown",
    "-debugcon","file:$dbg",
    "-device","rtl8139,netdev=net0",
    "-netdev","user,id=net0",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)

Start-Sleep -Milliseconds 1500

# --- Wait for test to complete ---
$deadline=(Get-Date).AddSeconds(30)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "PE exec returned OK" -or $l -match "VM OK" -or $l -match "DL:OK"){break}
    if($l -match "kernel halt" -or $l -match "PE exec FAILED"){break}
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 800

# --- Take screenshot via monitor ---
try{
    $sock=New-Object System.Net.Sockets.TcpClient("127.0.0.1",$mon)
    $s=$sock.GetStream(); $w=New-Object System.IO.StreamWriter($s); $w.AutoFlush=$true
    Start-Sleep -Milliseconds 150
    $w.WriteLine("screendump $ppm"); Start-Sleep -Milliseconds 600
    $w.WriteLine("quit"); Start-Sleep -Milliseconds 200
    $sock.Close()
}catch{ Write-Output "[warn] monitor: $_" }

Start-Sleep -Milliseconds 400
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$pyProc | Stop-Process -Force -ErrorAction SilentlyContinue

# --- Analyze ---
$l=ReadShared $dbg
Write-Output "`n=== net_test debug log (last 5000 chars) ==="
if($l.Length -gt 5000){ Write-Output $l.Substring($l.Length-5000) }
else{ Write-Output $l }

$serveLog = ReadShared "$root\win9x\winme\_serve_a4.log"
Write-Output "`n=== serve_a4 log ==="
Write-Output $serveLog

$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output "[PASS] $name"; $global:pass++ }
    else   { Write-Output "[FAIL] $name"; $global:fail++ }
}

Check "32-bit boot (boot32)"                ($l -match "boot32")
Check "kernel at 1MB"                       ($l -match "kernel at 1MB")
Check "A4X demo started"                    ($l -match "demo:start")
Check "RTL8139 NIC detected"                ($l -match "RTL8139" -or $l -match "rtl8139")
Check "ARP request sent"                    ($l -match "ARP: sending request")
Check "TCP SYN sent"                        ($l -match "TCP: SYN sent")
Check "TCP SYN-ACK / ESTABLISHED"           ($l -match "SYN-ACK received")
Check "HTTP GET sent"                       ($l -match "eth_send" -and $l -match "http")
Check "HTTP body complete"                  ($l -match "HTTP body complete")
Check "PE downloaded"                       ($l -match "PE downloaded")
Check "PE parse OK"                         ($l -match "PE parse OK")
Check "PE exec returned OK"                 ($l -match "PE exec returned OK")
Check "HTTP server served the exe"          ($serveLog -match "Served")

Write-Output "`nnet_test: PASS=$pass FAIL=$fail"
exit $(if($fail -eq 0){0}else{1})