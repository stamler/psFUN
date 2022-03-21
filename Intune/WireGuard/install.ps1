$localprograms = choco list --localonly
if ($localprograms -like "*wireguard*")
{
    choco upgrade wireguard -y
}
Else
{
    choco install wireguard -y
}
#C:\Program Files\WireGuard