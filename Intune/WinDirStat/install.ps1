$localprograms = choco list --localonly
if ($localprograms -like "*windirstat*")
{
    choco upgrade windirstat -y
}
Else
{
    choco install windirstat -y
}
#C:\Program Files (x86)\WinDirStat