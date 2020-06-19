$first = Read-Host "First Name"
$middle = Read-Host "Middle Name"
$last = Read-Host "Last Name"
$phone = Read-Host "Phone Number"

# Generate the username
if ( $middle.Length -ge 1) {
	$uname = $first.SubString(0,1).ToLower() + $middle.SubString(0,1).ToLower() + $last.ToLower()
} else {
	$uname = $first.SubString(0,1).ToLower() + $last.ToLower()
}

$upn = $uname + "@tbte.ca"

# Generate a password
$valid_pw = $false
$pw = $null
Do {
  $pw = -join ('abcdefghkmnrstuvwxyzABCDEFGHKLMNPRSTUVWXYZ23456789$%&*#'.ToCharArray() | Get-Random -Count 14)
  If ( 
    ($pw -cmatch "[A-Z]") `
    -and ($pw -cmatch "[a-z]") `
    -and ($pw -match "[\d]") `
    -and ($pw -match "[^\w ]") ) {
      $valid_pw = $true
    } else {
      $valid_pw = $false
    }
    $count ++
} while ($false -eq $valid_pw)
$SecurePassword = $pw | ConvertTo-SecureString -AsPlainText -Force

# Create the user
$user = New-ADUser `
 -Name "$first $last" `
 -Path "OU=Human Users,DC=main,DC=tbte,DC=ca" `
 -Company "TBT Engineering Limited" `
 -GivenName "$first" `
 -Surname "$last" `
 -SamAccountName "$uname" `
 -UserPrincipalName "$upn" `
 -OfficePhone "$phone" `
 -AccountPassword $SecurePassword `
 -Enabled $True `
 -OtherAttributes @{'mail'=$upn} `
 -PassThru

# Add user to groups
Add-ADGroupMember -Identity "TBTE_General" -Members $user

# Setup licensing group
$software = Read-Host "Does the user require a Desktop software license? [Yes/no]"
if ($software -eq 'Yes') {
	Write-Host "Adding the user to TBTE_Desktop_Software group..."
	Add-ADGroupMember -Identity "TBTE_Desktop_Software" -Members $user
} else {
	Write-Host "Adding the user to TBTE_Mobile_Software..."
	Add-ADGroupMember -Identity "TBTE_Mobile_Software" -Members $user
}

# Show the created username and password
Write-Output "$upn : $pw"

# Run an AzureAD sync, module must be installed
#Import-Module ADSync
#Start-ADSyncSyncCycle -PolicyType Delta