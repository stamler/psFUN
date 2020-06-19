$count = 0
$valid = $false
$pw = $null
Do {
  $pw = -join ('abcdefghkmnrstuvwxyzABCDEFGHKLMNPRSTUVWXYZ23456789$%&*#'.ToCharArray() | Get-Random -Count 14)
  If ( 
    ($pw -cmatch "[A-Z]") `
    -and ($pw -cmatch "[a-z]") `
    -and ($pw -match "[\d]") `
    -and ($pw -match "[^\w ]") ) {
      $valid = $true
    } else {
      $valid = $false
    }
    $count ++
} while ($false -eq $valid)

Write-Host "Generated $pw after $count tries"