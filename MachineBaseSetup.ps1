# If "ansible" account exists, ensure it's an admin and reset the password 
# then display the new password. If it doesn't exist, create it and show the
# password

# Create Output Object
$output = @{}

# Generate a password
Add-Type -AssemblyName 'System.Web'
$output["Password"] = [System.Web.Security.Membership]::GeneratePassword(14, 1)
$SecurePassword = $output["Password"] | ConvertTo-SecureString -AsPlainText -Force

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

# Get computer info
$c_bios = Get-WmiObject Win32_Bios
$c_system = Get-WmiObject Win32_ComputerSystem
$c_netset = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"

# Get IP Addresses
ForEach ($c_net in $c_netset) {
    # Iterate over array elements and assign type stringValue
    ForEach ($t in $c_net.IPAddress) {
        [array]$ip_list += $t
    }
    $output[$c_net.MACAddress] = $ip_list
}

# Generate proposed computer name from MFG/Serial/PCSystemType
$output["ProposedComputerName"] = ( 
        $( If ($c_system.PCSystemType -eq 2) {"M"} Else {"F"} ) + 
        $c_system.Manufacturer.Substring(0,2).ToUpper() + 
        "-" +  $c_bios.SerialNumber
    )

Write-Host "`n*********************************************************************" -ForegroundColor Yellow
Write-Host "Please copy the following information to IT, it will only appear once" -ForegroundColor Magenta
Write-Host "*********************************************************************" -ForegroundColor Yellow
Write-Output $output

# Prompt to rename computer if proposed name is different
if ($env:COMPUTERNAME -ne $output["ProposedComputerName"]) {
    Write-Host "`nExisting name $($env:COMPUTERNAME) doesn't match $($output['ProposedComputerName'])"
    $confirm = Read-Host "`nRename the computer and reboot? [Yes/no]"
    if ($confirm -eq 'Yes') {
        Write-Host "Renaming the computer..."
        Rename-Computer -NewName $output["ProposedComputerName"] -Force -Restart
    } else {
        Write-Host "The computer was not renamed."
    }
}
 
