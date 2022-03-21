$localprograms = choco list --localonly
if ($localprograms -like "*pdfsam*")
{
    choco upgrade pdfsam -y
}
Else
{
    choco install pdfsam -y
}
#C:\Program Files\PDFsam Basic\