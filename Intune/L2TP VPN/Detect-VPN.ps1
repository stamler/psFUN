$ConnectionName = "TBT Engineering Limited L2TP"
if (Get-VpnConnection -Name $ConnectionName -AllUserConnection -ErrorAction SilentlyContinue) {
  Write-Output "VPN configured"
  Exit 0
} Else {
  Write-Output "VPN not configured"
  Exit 1
}