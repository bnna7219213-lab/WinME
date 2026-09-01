# win98/verify.ps1 — Verify the Win98 generation (M-A3: VMM/VxD era)
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\win98\win98.img"
$dbg  = "$root\win9x\win98\_win98.log"

function ReadShared($path){
    if(-not(Test-Path $path)){return ""}
    try{
        $fs=New-Object System.IO.FileStream($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sr=New-Object System.IO.StreamReader($fs)
        $t=$sr.ReadToEnd(); $sr.Close();$fs.Close(); return $t
    }catch{return ""}
}

Remove-Item $dbg -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300

$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot","-debugcon","file:$dbg"
)
Start-Sleep -Seconds 5
if(-not $p.HasExited){ try{ $p.Kill() }catch{} }
Start-Sleep -Milliseconds 400
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$l=ReadShared $dbg
Write-Output "=== win98 debug log ==="
Write-Output $l

$pass=0; $fail=0
function Check($name,$ok){
    if($ok){ Write-Output ("[PASS] "+$name); $global:pass++ }
    else   { Write-Output ("[FAIL] "+$name); $global:fail++ }
}
Check "M-A3 kernel banner (Win9x Axis / M-A3)" ($l -match "M-A3")
Check "PM ON - VMM32 starting"            ($l -match "PM ON - VMM32 starting")
Check "Sys VM + DOS VM created"           ($l -match "Sys VM \+ DOS VM created")
Check "VTD timer armed on IRQ0"           ($l -match "virtual timer device armed")
Check "round-robin scheduler ran"         ($l -match "scheduler start")
Check "Sys/Dos VM ticks non-zero"         ($l -match "VM SYS  ticks=([1-9]\d*)")
Check "demo complete (BACK IN REAL MODE)" ($l -match "BACK IN REAL MODE - VMM demo complete")

Write-Output ("`nwin98: PASS="+$pass+" FAIL="+$fail)
exit $(if($fail -eq 0){0}else{1})
