# run_net_test_gdb.ps1 — Real network test with GDB-assisted TCTL write
# QEMU 11.0.50 has a bug where MMIO writes to TCTL (0x0410) are silently
# dropped. This script uses GDB to write TCTL directly after the kernel boots.
$ErrorActionPreference = "Continue"
$root  = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu  = "C:\qemu\qemu-system-i386.exe"
$gdb   = "C:\mingw64\mingw64\bin\gdb.exe"
$img   = "$root\win9x\winme\winme_net.img"
$dbg   = "$root\win9x\winme\_net_test.log"
$ppm   = "$root\win9x\winme\_net_test.ppm"
$mon   = 4512
$gdbpt = 1234
$py    = "python"

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

# --- Start Python HTTP server ---
Write-Output "[net_test] Starting Python HTTP server on port 8080..."
$pyProc = Start-Process -FilePath $py -ArgumentList "$root\win9x\winme\serve_a4.py" -PassThru -NoNewWindow -RedirectStandardOutput "$root\win9x\winme\_serve_a4.log" -RedirectStandardError "$root\win9x\winme\_serve_a4.err"
Start-Sleep -Milliseconds 800
if($pyProc.HasExited){
    Write-Output "[FAIL] Python HTTP server failed to start"
    exit 1
}
Write-Output "[net_test] HTTP server running (PID=$($pyProc.Id))"

# --- Launch QEMU with GDB stub ---
Write-Output "[net_test] Launching QEMU with GDB stub on port $gdbpt..."
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot",
    "-debugcon","file:$dbg",
    "-device","e1000,netdev=net0",
    "-netdev","user,id=net0",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait",
    "-gdb","tcp:127.0.0.1:$gdbpt,server,nowait"
)

# --- Wait for kernel to boot and reach state=3 (SYN sent) ---
Write-Output "[net_test] Waiting for kernel to boot and send SYN..."
$deadline=(Get-Date).AddSeconds(10)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "TCP: SYN sent"){break}
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Milliseconds 1000  # Give time for TDT to be written

# --- Use GDB to write TCTL ---
Write-Output "[net_test] Using GDB to set TCTL=0x010A (workaround for QEMU MMIO bug)..."

# Create GDB command file
$gdbCmds = @"
set pagination off
set confirm off
target remote 127.0.0.1:$gdbpt
set *(unsigned int*)0xFEBC0410 = 0x0000010A
printf "TCTL after GDB write: 0x%08x\n", *(unsigned int*)0xFEBC0410
set *(unsigned int*)0xFEBC0410 = 0x0000010A
printf "TCTL after 2nd write: 0x%08x\n", *(unsigned int*)0xFEBC0410
detach
quit
"@
$gdbCmds | Out-File -FilePath "$root\win9x\winme\_gdb_cmds.txt" -Encoding ASCII

# Run GDB with the command file
$gdbOutput = & $gdb -batch -x "$root\win9x\winme\_gdb_cmds.txt" 2>&1
Write-Output "[net_test] GDB output:"
Write-Output $gdbOutput

# --- Wait for download to complete ---
Write-Output "[net_test] Waiting for download and execution..."
$deadline=(Get-Date).AddSeconds(20)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "DL:OK" -or $l -match "VM OK"){break}
    if($l -match "kernel halt"){break}
    Start-Sleep -Milliseconds 300
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
}catch{ Write-Output ("[warn] monitor: "+$_) }

Start-Sleep -Milliseconds 400
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# --- Stop Python server ---
$pyProc | Stop-Process -Force -ErrorAction SilentlyContinue

# --- Analyze results ---
$l=ReadShared $dbg
Write-Output "`n=== net_test debug log (first 2000 chars) ==="
if($l.Length -gt 2000){ Write-Output $l.Substring(0,2000) }
else{ Write-Output $l }

Write-Output "`n=== net_test debug log (last 2000 chars) ==="
if($l.Length -gt 2000){ Write-Output $l.Substring($l.Length-2000) }
else{ Write-Output $l }

# --- Check serve_a4 log ---
$serveLog = ReadShared "$root\win9x\winme\_serve_a4.log"
Write-Output "`n=== serve_a4 log ==="
Write-Output $serveLog

# --- Pass/fail checks ---
$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output ("[PASS] "+$name); $global:pass++ }
    else   { Write-Output ("[FAIL] "+$name); $global:fail++ }
}

Check "32-bit boot (boot32)"                   ($l -match "boot32")
Check "kernel at 1MB"                          ($l -match "kernel at 1MB")
Check "A4X demo started"                       ($l -match "demo:start")
Check "ARP skipped (SLIRP gateway MAC set)"    ($l -match "ARP: skipped")
Check "TCP SYN-ACK received (handshake OK)"    ($l -match "SYN-ACK received")
Check "TCP data sent (HTTP GET)"               ($l -match "TCP: data sent")
Check "TCP data received (HTTP response)"      ($l -match "data received")
Check "Downloaded bytecode executed (DL:OK)"   ($l -match "DL:OK")
Check "VM execution completed (VM OK)"         ($l -match "VM OK")
Check "HTTP server served the exe"             ($serveLog -match "Served")

if(Test-Path $ppm){
    $b=[System.IO.File]::ReadAllBytes($ppm)
    if($b.Length -gt 1000){ Write-Output ("[PASS] screenshot captured ("+$b.Length+" bytes)"); $pass++ }
    else { Write-Output "[FAIL] screenshot too small"; $fail++ }
} else { Write-Output "[FAIL] no screenshot"; $fail++ }

Write-Output ("`nnet_test: PASS="+$pass+" FAIL="+$fail)
exit $(if($fail -eq 0){0}else{1})
