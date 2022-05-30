Param(
  [Parameter(Mandatory=$true)]
  [String]$Group
)
Get-ADGroupMember -Identity $Group -Recursive | Get-ADUser -Properties Mail | Select-Object Name,Mail | ForEach-Object { "`"$($_.Name)`" <$($_.Mail)>"} 
