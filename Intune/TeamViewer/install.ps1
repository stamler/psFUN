$localprograms = choco list --localonly
if ($localprograms -like "*teamviewer*")
{
    choco upgrade teamviewer -y
}
Else
{
    choco install teamviewer -y
}