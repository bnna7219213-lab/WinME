Set-Location 'c:\Users\bnna7\workspace\msdos-kernel\win9x\winme'
$output = & .\build.bat 2>&1
$output | ForEach-Object { $_.ToString() }
