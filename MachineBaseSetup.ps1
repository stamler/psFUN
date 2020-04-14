# If "ansible" account exists, ensure it's an admin and reset the password 
# then display the new password. If it doesn't exist, create it and show the
# password

# Generate a password
Add-Type -AssemblyName 'System.Web'
$Password = [System.Web.Security.Membership]::GeneratePassword(14, 1)
$SecurePassword = $Password | ConvertTo-SecureString -AsPlainText -Force

try {
    # Powershell Try/Catch only works with terminating errors, use ErrorAction
    $AnsibleUser = Get-LocalUser "ansible" -ErrorAction Stop
    Write-Output "Resetting existing ansible user's password..."
    Set-LocalUser -InputObject $AnsibleUser -Password $SecurePassword
}
catch [Microsoft.PowerShell.Commands.UserNotFoundException] {
    Write-Output "Creating new ansible user..."
    New-LocalUser "ansible" -Password $SecurePassword -FullName "Ansible"
}

try {
    Add-LocalGroupMember -Group "Administrators" -Member "ansible" -ErrorAction Stop
}
catch {
    Write-Output "ansible is already a member of the Administrators group"    
}

# TODO: Enable WinRM per ansible docs then alert user

# Get computer info and display output
$c_bios = Get-WmiObject Win32_Bios
$c_system = Get-WmiObject Win32_ComputerSystem

# Generate new computer name from MFG/Serial/PCSystemType
$NewComputerName = ( 
        $( If ($c_system.PCSystemType -eq 2) {"M"} Else {"F"} ) + 
        $c_system.Manufacturer.Substring(0,2).ToUpper() + 
        "-" +  $c_bios.SerialNumber
    )

Write-Output $IPAddresses
Write-Output "ansible account password: $($Password)"
Write-Output "proposed computer name: $($NewComputerName)"

# TODO: Prompt to rename computer (Type 'Yes')
 
 
