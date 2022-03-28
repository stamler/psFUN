$ConnectionName = "TBT Engineering Limited L2TP"
Remove-VpnConnection -Name $ConnectionName -AllUserConnection -Force -ErrorAction SilentlyContinue