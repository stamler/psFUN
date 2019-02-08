# Get all of the active directory users with their ms-DS-ConsistencyGuid values
# and write it to the current directory as output.csv. User running script
# will need access to the properties in AD, so running as admin works.
# Tested on PowerShell 5.1

$OUDN = "OU=Human Users,DC=main,DC=tbte,DC=ca"
$user_set = Get-ADUser -SearchBase $OUDN -Filter * -Properties sAMAccountName, mS-DS-ConsistencyGuid, userPrincipalName
$output = New-Object System.Collections.ArrayList
foreach ($user in $user_set) {
  $temp = @{
    sAMAccountName = $user.sAMAccountName
    'ms-DS-ConsistencyGuid' = [System.Convert]::ToBase64String($user.'ms-DS-ConsistencyGuid')
    sourceAnchor = [System.BitConverter]::ToString($user.'mS-DS-ConsistencyGuid').Replace("-","").ToLower()
    userPrincipalName = $user.userPrincipalName
  }
  $output.Add($temp)
}
$output.ForEach({[PSCustomObject]$_}) | Export-Csv -Path output.csv