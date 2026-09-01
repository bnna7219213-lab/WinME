# winme/verify.ps1 — Verify the WinMe generation (M-A4 GUI, real-mode-free)
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\winme\winme.img"
$dbg  = "$root\win9x\winme\_winme.log"
$ppm  = "$root\win9x\winme\_winme.ppm"
$pcap = "$root\win9x\winme\_net.pcap"
$mon  = 4511
$serveLog = "$root\win9x\winme\_serve_a4.log"

function ReadShared($path){
    if(-not(Test-Path $path)){return ""}
    try{
        $fs=New-Object System.IO.FileStream($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr=New-Object System.IO.StreamReader($fs)
        $t=$sr.ReadToEnd(); $sr.Close();$fs.Close(); return $t
    }catch{return ""}
}

Remove-Item $dbg,$ppm,$serveLog,$pcap -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*serve_a4*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300

# RTL8139 NIC + guestfwd (guest 10.0.2.2:8081 → local PE server) + pcap capture for network debugging.
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot",
    "-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait",
    "-netdev","user,id=n0",
    "-device","rtl8139,netdev=n0",
    "-object","filter-dump,id=f0,netdev=n0,file=$pcap"
)

# P0 install-pipeline: extend deadline to 90s so VM gets HTTP response,
# runs fs_install_exe, executes installed bytecode (PRINT + DELAY + PRINT + HALT).
$deadline=(Get-Date).AddSeconds(90)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "kernel halt" -or $l -match "\[PE\] exec returned OK"){break}
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 600

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
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*serve_a4*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$l=ReadShared $dbg
Write-Output "=== winme debug log ==="
Write-Output $l

$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output ("[PASS] "+$name); $global:pass++ }
    else   { Write-Output ("[FAIL] "+$name); $global:fail++ }
}

Check "32-bit loader (boot32, no M0 real-mode boot)" ($l -match "boot32")
Check "protected mode ON"                             ($l -match "PM ON")
Check "paging ON"                                     ($l -match "paging ON")
Check "kernel loaded at 1MB (flat 32-bit)"            ($l -match "kernel at 1MB")
Check "A4X demo start"                                ($l -match "\[A4X\] demo:start")
Check "A4X desktop drawn"                             ($l -match "\[A4X\] demo:desktop")
Check "A4X taskbar drawn"                             ($l -match "\[A4X\] demo:taskbar")
Check "A4X app window drawn"                          ($l -match "\[A4X\] demo:appwnd")
Check "A4X close button drawn"                        ($l -match "\[A4X\] demo:closebtn")
Check "VIN script loaded (VMM/VxD message path)"      ($l -match "VIN script loaded")
Check "A4X DONE"                                      ($l -match "\[A4X\] DONE")
Check "RTL8139 NIC detected by kernel"                ($l -match "RTL8139 initialized OK")
Check "TCP SYN packet sent"                           ($l -match "TCP: SYN sent")
Check "TCP TX completed (OWN cleared)"                ($l -match "tcp_check TX DONE")
Check "TCP SYN-ACK received (handshake)"              ($l -match "SYN-ACK received")
Check "TCP ESTABLISHED state reached"                 ($l -match "ESTABLISHED")
Check "HTTP GET request sent over TCP"                ($l -match "TCP: data sent")
Check "HTTP response received from server"            ($l -match "TCP data received")
# P0: PE path sets dl_valid=3; legacy bytecode path sets dl_valid=2
Check "PE downloaded + parsed (dl_valid=3) OR bytecode installed (dl_valid=2)" (($l -match "dl_valid=3") -or ($l -match "dl_valid  = 3") -or ($l -match "dl_valid=2") -or ($l -match "dl_valid  = 2"))
Check "real-mode 'MS-DOS' banner ABSENT (boot path removed)" (-not ($l -match "MS-DOS"))
# PE-specific markers (added in Task 10 for end-to-end verification)
Check "PE download+parse debug marker present"   ($l -match "\[PE\] dl\+parse OK")
Check "PE exec returned to GUI"                  ($l -match "\[PE\] exec returned OK")

# Cross-check: serve_a4.py should have logged a GET request from 10.0.2.15
$serveOut = ReadShared $serveLog
Check "serve_a4.py received GET /a4.exe"              ($serveOut -match "Served .* bytes to")

if(Test-Path $ppm){
    $b=[System.IO.File]::ReadAllBytes($ppm)
    if($b.Length -gt 1000){ Write-Output ("[PASS] screenshot captured ("+$b.Length+" bytes)"); $pass++ }
    else { Write-Output "[FAIL] screenshot too small"; $fail++ }
} else { Write-Output "[FAIL] no screenshot"; $fail++ }

Write-Output ("`nwinme: PASS="+$pass+" FAIL="+$fail)
exit $(if($fail -eq 0){0}else{1})
