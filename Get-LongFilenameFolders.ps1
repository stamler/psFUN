"2015","2016","2017","2018","2019","2020","2021","2022" | ForEach-Object {
  Get-ChildItem -Path "F:\projects\Projects\$_" -Recurse | Where-Object {$_.FullName.Length -gt 260 } | Select-Object @{Name=”MaxLength”;Expression={$_.fullname.length}}, @{Name="Folder";Expression={$_.FullName | Split-Path -Parent}} | Group-Object -Property Folder | ForEach-Object {$_.Group | Sort-Object MaxLength -Descending | Select-Object -First 1} 
} 
