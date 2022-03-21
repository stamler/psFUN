$sources = choco source list
if ($sources -like "*onprem*") {
  Write-Output "Chocolatey configured"
  Exit 0
} Else {
  Exit 1
}