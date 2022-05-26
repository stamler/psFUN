$path = "F:\projects\Projects\2017"
Get-ChildItem -Path $path -Recurse | Where-Object {$_.FullName.Length -gt 260 } | Select-Object @{Name=”MaxLength”;Expression={$_.fullname.length}}, @{Name="Folder";Expression={$_.FullName | Split-Path -Parent}} | Group-Object -Property Folder | ForEach-Object {$_.Group | Sort-Object MaxLength -Descending | Select-Object -First 1}
