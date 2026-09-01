# run_real_inet_test.ps1 — Validate real-internet PE download + install into OS
#
# -DnsTest : DNS-path variant.  Builds nothing; expects winme_net_dns.img
#            (built via build_net.ps1 -DnsTest, dl_url_str=httpbin.org/bytes/256).
#            Guest must resolve the hostname via UDP DNS (223.5.5.5 through
#            SLiRP NAT), TCP-connect to the resolved public IP and complete an
#            HTTP GET to httpbin.org.  No local server and no PE assertions
#            (httpbin payload is random bytes, not an MZ executable).
#
# Scenario:
#   1. Run serve_real_inet.py:
#        - performs a REAL outbound HTTP request to httpbin.org (proves host
#          internet reachable through its real NIC)
#        - listens on 127.0.0.1:8080 and serves hello.exe (or a real remote
#          exe if --url is supplied) with valid HTTP headers
#   2. Launch QEMU i386 with -netdev user (SLiRP NAT).  Emulated kernel:
#        - ARPs 10.0.2.2 (SLiRP gateway = host)
#        - TCP connects 10.0.2.2:8080 -> our Python server
#        - GET /a4.exe -> receive PE bytes
#        - pe_parse -> pe_load -> pe_resolve_imports -> pe_exec ->
#          fs_install_pe_exe registers "inet_dl.exe" in file_table with
#          content_off + content_len and occupies file_contents_pool chunks
#   3. Inspect debug log for:
#        - [inet_xxx]  probe markers
#        - PE downloaded / PE parse OK / PE exec returned OK
#        - [A4X] PE installed to OS OK        (NEW: proves install happened)
#        - [A4X] fpe: installed slot=X off=Y len=Z  (concrete FS state)
#   4. Bonus: compare PE bytes in dbg log via pe_download_len match vs.
#      file_table FS_CONTENT_LEN match, plus first bytes match MZ (checked
#      indirectly by pe_parse passing).

param([switch]$DnsTest)
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\winme\winme_net.img"
$dbg  = "$root\win9x\winme\_real_inet_test.log"
$ppm  = "$root\win9x\winme\_real_inet_test.ppm"
$mon  = 4513
$pcap = "$root\win9x\winme\_real_inet_test.pcap"
$py   = "python"
$pyLog= "$root\win9x\winme\_serve_real_inet.log"
$pyErr= "$root\win9x\winme\_serve_real_inet.err"
if($DnsTest){
    $img  = "$root\win9x\winme\winme_net_dns.img"
    $dbg  = "$root\win9x\winme\_dns_test.log"
    $ppm  = "$root\win9x\winme\_dns_test.ppm"
    $pcap = "$root\win9x\winme\_dns_test.pcap"
}

function ReadShared($path){
    if(-not(Test-Path $path)){return ""}
    try{
        $fs=New-Object System.IO.FileStream($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr=New-Object System.IO.StreamReader($fs)
        $t=$sr.ReadToEnd(); $sr.Close();$fs.Close(); return $t
    }catch{return ""}
}

# --- Cleanup ---
Remove-Item $dbg,$ppm,$pyLog,$pyErr,$pcap -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process python* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Also release TCP port 8080 explicitly (some python sockets linger)
try {
    $pids = Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($pid in $pids) {
        if($pid -and $pid -ne 0) {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Write-Output "[real_inet] Killed lingering PID $pid holding :8080"
        }
    }
} catch {}
Start-Sleep -Milliseconds 800

# --- Start real-inet proxy HTTP server on port 8080 (not needed for DNS test) ---
$pyProc = $null
if(-not $DnsTest){
    Write-Output "[real_inet] Starting serve_real_inet.py on port 8080..."
    $argList = @("-u", "$root\win9x\winme\serve_real_inet.py", "--port", "8080")
    $pyProc = Start-Process -FilePath $py -ArgumentList $argList -PassThru -NoNewWindow `
                             -RedirectStandardOutput $pyLog -RedirectStandardError $pyErr
    Start-Sleep -Milliseconds 2500  # wait for internet probe to finish

    if($pyProc.HasExited){
        Write-Output "[FAIL] Python real-inet server failed to start (exit=$($pyProc.ExitCode))"
        Get-Content $pyErr -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Output "[real_inet] HTTP server running (PID=$($pyProc.Id))"
    $serve = ReadShared $pyLog
    Write-Output "--- serve_real_inet startup log ---"
    Write-Output $serve
    if($serve -notmatch "Payload selected"){
        Write-Output "[WARN] server did not finish init before timeout, continuing anyway..."
    }
} else {
    Write-Output "[dns_test] Skipping local server (guest downloads straight from the internet)"
}

# --- Launch QEMU ---
Write-Output "[real_inet] Launching QEMU with RTL8139 / user-net NAT..."
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot","-no-shutdown",
    "-debugcon","file:$dbg",
    "-device","rtl8139,netdev=net0",
    "-netdev","user,id=net0",
    "-object","filter-dump,id=fd0,netdev=net0,file=$(($pcap -replace '\\','/'))",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)

Start-Sleep -Milliseconds 1800

# --- Wait for test to complete ---
$deadline=(Get-Date).AddSeconds(35)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "PE installed to OS OK" -or $l -match "inet_dl.exe" -or $l -match "VM OK"){break}
    if($l -match "kernel halt" -or $l -match "PE install to OS FAILED"){break}
    if($l -match "HTTP body complete"){break}
    if($l -match "DNS resolve FAILED 3x"){break}
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Milliseconds 800

# --- Take screenshot via monitor & quit ---
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
$tag = "real_inet"
if($DnsTest){ $tag = "dns_test" }
Write-Output "`n=== $tag debug log (last 6000 chars) ==="
if($l.Length -gt 6000){ Write-Output $l.Substring($l.Length-6000) } else { Write-Output $l }

$serveLog = ""
if(-not $DnsTest){
    $serveLog = ReadShared $pyLog
    Write-Output "`n=== serve_real_inet log ==="
    Write-Output $serveLog
}

# --- Assessment helpers ---
$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output "[PASS] $name"; $global:pass++ }
    else   { Write-Output "[FAIL] $name"; $global:fail++ }
}

if($DnsTest){
    # ============ DNS-path assertion set (no local server, no PE) ============
    Check "32-bit boot (boot32)"                              ($l -match "boot32")
    Check "A4X demo started"                                  ($l -match "demo:start")
    Check "RTL8139 NIC detected"                              ($l -match "RTL8139" -or $l -match "rtl8139")
    Check "ARP request sent"                                  ($l -match "ARP: sending request")
    Check "net_dl state=2 (DNS resolve)"                      ($l -match "net_dl state=2 \(DNS resolve\)")
    Check "hostname extracted from URL"                       ($l -match "dl: resolving hostname=httpbin\.org")
    Check "DNS query sent (udp_send)"                         ($l -match "DNS: query sent")
    Check "DNS response parsed (A record)"                    ($l -match "dl: DNS OK dword=")
    Check "resolved IP is public (not 10.x)"                  ($l -match "dl: DNS OK dword=(?!0A00020)" )
    Check "TCP SYN sent to resolved IP"                       ($l -match "TCP: SYN sent")
    Check "TCP SYN-ACK / ESTABLISHED"                         ($l -match "SYN-ACK received")
    Check "HTTP GET sent"                                     ($l -match "TCP: data sent")
    Check "HTTP body complete (httpbin payload)"              ($l -match "HTTP body complete")
    Write-Output "`ndns_test: PASS=$pass FAIL=$fail"
    exit $(if($fail -eq 0){0}else{1})
}

# A. Real internet connectivity (host side, from serve_real_inet log)
Check "Real internet probe OK (host side)"              (($serveLog -match "Internet probe OK") -or ($serveLog -match "Using REAL remote payload"))
Check "serve_real_inet served a payload"                 ($serveLog -match "Served \d+ bytes to")

# B. Kernel boot + NIC
Check "32-bit boot (boot32)"                              ($l -match "boot32")
Check "kernel at 1MB"                                     ($l -match "kernel at 1MB")
Check "A4X demo started"                                  ($l -match "demo:start")
Check "RTL8139 NIC detected"                              ($l -match "RTL8139" -or $l -match "rtl8139")

# C. Network stack
Check "ARP request sent"                                  ($l -match "ARP: sending request")
Check "TCP SYN sent"                                      ($l -match "TCP: SYN sent")
Check "TCP SYN-ACK / ESTABLISHED"                         ($l -match "SYN-ACK received")
Check "HTTP GET sent"                                     ($l -match "eth_send" -and $l -match "http")
Check "HTTP body complete"                                ($l -match "HTTP body complete")

# D. PE download + parse + exec
Check "PE downloaded (MZ detected)"                       ($l -match "PE downloaded")
Check "PE parse OK"                                       ($l -match "PE parse OK")
Check "PE imports resolved (IAT0 written, non-0)"         ($l -match "imports ret IAT0=(?!00000000)[0-9A-F]{8}")
Check "PE exec returned OK"                               ($l -match "PE exec returned OK")

# E. PE INSTALL into file_table (new, the crux of this test)
Check "fs_install_pe_exe length/chunks probe"             ($l -match "\[A4X\] fpe: len=")
Check "PE installed to OS OK (new)"                       ($l -match "\[A4X\] PE installed to OS OK")
Check "fpe: recorded slot/off/len in debug"               ($l -match "fpe: installed slot=")

# F. Verify installed inet_dl.exe content_len consistency + MZ/PE sig
$dlLen = ""
$insLen = ""
if($l -match "PE downloaded.*len=([0-9A-F]{8})")      { $dlLen  = $Matches[1] }
if($l -match "fpe: installed slot=.*len=([0-9A-F]{8})") { $insLen = $Matches[1] }
$lenCheck = $false
if($dlLen -and $insLen){
    $dl  = [Convert]::ToInt32($dlLen, 16)
    $ins = [Convert]::ToInt32($insLen, 16)
    $diff = [Math]::Abs($dl - $ins)
    $lenCheck = ($diff -le 1) -and ($ins -gt 0)
    Write-Output ("[info] pe_download_len=0x{0} ({1}B)  installed_content_len=0x{2} ({3}B)  diff={4}" -f $dlLen,$dl,$insLen,$ins,$diff)
}
Check "installed inet_dl.exe content_len ~= PE len"      $lenCheck
Check "inet_dl.exe MZ+PE signature verified in pool"     ($l -match "MZ\+PE signature OK")
Check "installed PE re-loaded from file_table (Prio 0.5, buf poisoned)" ($l -match "installed PE re-loaded from file_table OK")

# G. P1.6 GUI double-click launch of installed EXE (desktop icon click)
#    Exact same pe_pending_run path that a real fs_hit_test click arms.
#    We see the arming line → exe_load(Prio 0.5) in main_loop dispatch →
#    pe_exec runs → "PE launched" line shows exit_code=00000000 success.
Check "P1.6 icon-click runner armed (sim click slot 7)"   ($l -match "p16: armed pending run for slot 7")
Check "P1.6 EXE ran from icon click (exit_code=0)"        ($l -match "fs_icon: PE launched from icon click exit_code=00000000")

Write-Output "`nreal_inet_test: PASS=$pass FAIL=$fail"
exit $(if($fail -eq 0){0}else{1})
