Get-Process | Where-Object { $_.ProcessName -match 'qemu|python' } | Format-Table Id, ProcessName, StartTime -AutoSize
