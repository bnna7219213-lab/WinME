$items = @("build.bat","winme.img","build/hello.exe")
foreach ($f in $items) {
    $p = Join-Path (Get-Location) $f
    if (Test-Path $p) {
        $i = Get-Item $p
        Write-Output "$($i.Name)  size=$($i.Length)  mtime=$($i.LastWriteTime)"
    } else {
        Write-Output "$f  NOT FOUND"
    }
}