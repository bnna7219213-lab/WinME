Write-Output "starting qemu"
$p = Start-Process -FilePath "C:\qemu\qemu-system-i386.exe" -PassThru -NoNewWindow -ArgumentList @("-fda","win9x\win9x.img","-boot","a","-m","16","-display","none","-no-reboot")
Write-Output ("qemu pid=" + $p.Id)
Start-Sleep -Seconds 3
Write-Output "killing"
try { $p.Kill() } catch { Write-Output ("kill err: " + $_) }
Start-Sleep -Seconds 1
Write-Output ("hasExited=" + $p.HasExited)
Write-Output "done"
