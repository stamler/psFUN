[CmdletBinding()]
param (
  [Parameter()]
  [String]
  $l2tppsk
)

$ConnectionName = "TBT Engineering Limited L2TP"

try {
  Add-VpnConnection -Name "TBT Engineering Limited L2TP" -ServerAddress "vpn.tbte.ca" -AllUserConnection -TunnelType "L2tp" -L2tpPsk $l2tppsk -EncryptionLevel "Required" -AuthenticationMethod "Chap","MSChapv2" -Force
}
catch [Microsoft.Management.Infrastructure.CimException] {
  Write-Host "VPN connection $ConnectionName already exists"
}