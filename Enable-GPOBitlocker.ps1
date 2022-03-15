# Enable bitlocker on computers that have been configured for it by running this
# script from scheduled tasks
$BLV = Get-BitLockerVolume -MountPoint 'C:'
if ($BLV.volumeStatus -eq 'FullyDecrypted') {
    # Create the key protector to be pushed to Active Directory
    Add-BitLockerKeyProtector -MountPoint 'c:' -RecoveryPasswordProtector
    # Enable Bitlocker
    Enable-Bitlocker -MountPoint 'c:' -TpmProtector
}