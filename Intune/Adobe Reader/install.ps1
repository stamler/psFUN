$localprograms = choco list --localonly
if ($localprograms -like "*adobereader*")
{
    choco upgrade adobereader -y
}
Else
{
    choco install adobereader -y
}