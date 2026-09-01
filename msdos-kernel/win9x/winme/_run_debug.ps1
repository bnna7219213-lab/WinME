$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\winme.img"
$dbg  = "c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_winme.log"
$intlog = "c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_intlog.txt"

Remove-Item $dbg,$intlog -Force -ErrorAction SilentlyContinue
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force

# Run QEMU with int logging to see exactly what exception occurs
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda",$img,"-boot","a","-m","16",
    "-display","none","-no-reboot",
    "-debugcon","file:$dbg",
    "-d","int","-D","$intlog"
)
Start-Sleep -Seconds 5
if(-not $p.HasExited){ $p.Kill(); $p.WaitForExit(3000) }

Write-Output "=== debugcon log ==="
$fs = New-Object System.IO.FileStream($dbg, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$sr = New-Object System.IO.StreamReader($fs)
Write-Output $sr.ReadToEnd()
$sr.Close(); $fs.Close()

Write-Output "`n=== int log (last 100 lines) ==="
if(Test-Path $intlog){
    $lines = Get-Content $intlog -Tail 100
    $lines | ForEach-Object { Write-Output $_ }
}
