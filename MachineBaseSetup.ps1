# If "ansible" account exists, ensure it's an admin and reset the password 
# then display the new password. If it doesn't exist, create it and show the
# password

# TODO: Generate real password
$Password = "A5BdC12d314x^!"
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

Add-LocalGroupMember -Group "Administrators" -Member "ansible"    

# TODO: Enable WinRM per ansible docs then alert user

# Get computer info and display output
$c_bios = Get-WmiObject Win32_Bios
$c_system = Get-WmiObject Win32_ComputerSystem
Write-Output $c_system.Manufacturer
Write-Output $c_bios.SerialNumber
Write-Output ($c_system.PCSystemType -eq 2)
# TODO: Generate computer name from MFG/Serial/PCSystemType
Write-Output $Password
Write-Output $IPAddresses
Write-Output $NewComputerName

# TODO: Prompt to rename computer
