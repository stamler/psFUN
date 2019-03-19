# Call with forceLogout -computer <COMPUTER IP OR DNS NAME>
# Invoke-CimMethod only works in PS3+
param (
    [Parameter(Mandatory=$true)][string]$computer
 )
$c = Get-Credential
Invoke-CimMethod -ClassName Win32_Operatingsystem -ComputerName $computer -MethodName Win32Shutdown -Arguments @{ Flags = 4 }