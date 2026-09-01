param([string]$Pattern, [string]$Path)
Select-String -Path $Path -Pattern $Pattern | ForEach-Object {
    '{0}:{1}' -f $_.LineNumber, $_.Line.Trim()
}
