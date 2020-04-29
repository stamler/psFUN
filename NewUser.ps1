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
Add-Type -AssemblyName 'System.Web'
$pw = [System.Web.Security.Membership]::GeneratePassword(14, 1)
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

# Show the created username and password
Write-Output "$upn : $pw"

# Run an AzureAD sync, module must be installed
#Import-Module ADSync
#Start-ADSyncSyncCycle -PolicyType Delta