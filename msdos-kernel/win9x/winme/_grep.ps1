param([string]$Pattern, [string]$Path)
Select-String -Path $Path -Pattern $Pattern | ForEach-Object { $_.Line }
