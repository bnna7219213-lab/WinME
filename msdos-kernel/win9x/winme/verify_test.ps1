# winme/verify_test.ps1 — Verify NET_TEST download-and-execute path
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\winme\winme_test.img"
$dbg  = "$root\win9x\winme\_winme_test.log"
$ppm  = "$root\win9x\winme\_winme_test.ppm"
$mon  = 4512

function ReadShared($path){
    if(-not(Test-Path $path)){return ""}
    try{
        $fs=New-Object System.IO.FileStream($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr=New-Object System.IO.StreamReader($fs)
        $t=$sr.ReadToEnd(); $sr.Close();$fs.Close(); return $t
    }catch{return ""}
}

Remove-Item $dbg,$ppm -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot",
    "-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)

# Wait longer (30s) since the install progress bar takes ~400 ticks
$deadline=(Get-Date).AddSeconds(30)
while((Get-Date) -lt $deadline){
    $l=ReadShared $dbg
    if($l -match "VM halted"){break}
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 1000

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

$l=ReadShared $dbg
Write-Output "=== winme NET_TEST debug log (tail) ==="
$lines = $l -split "`n"
$lines | Select-Object -Last 30 | ForEach-Object { Write-Output $_ }

$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output ("[PASS] "+$name); $global:pass++ }
    else   { Write-Output ("[FAIL] "+$name); $global:fail++ }
}

Check "boot32 loader"                        ($l -match "boot32")
Check "PM ON"                                ($l -match "PM ON")
Check "kernel at 1MB"                        ($l -match "kernel at 1MB")
Check "VIN demo start"                       ($l -match "\[A4X\] demo:start")
Check "NET_TEST bytecode injected"           ($l -match "NET_TEST: injected")
Check "VM halted (execution completed)"      ($l -match "VM halted")
Check "A4X DONE (demo completed)"            ($l -match "\[A4X\] DONE")

if(Test-Path $ppm){
    $b=[System.IO.File]::ReadAllBytes($ppm)
    if($b.Length -gt 1000){
        Write-Output ("[PASS] screenshot captured ("+$b.Length+" bytes)")
        $pass++
        $ppmDest = "$root\win9x\winme\_winme_test.ppm"
        Write-Output "  Screenshot: $ppmDest"
    } else { Write-Output "[FAIL] screenshot too small"; $fail++ }
} else { Write-Output "[FAIL] no screenshot"; $fail++ }

Write-Output ("`nwinme NET_TEST: PASS="+$pass+" FAIL="+$fail)
exit $(if($fail -eq 0){0}else{1})
