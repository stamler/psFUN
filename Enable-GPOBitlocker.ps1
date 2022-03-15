$BLV = Get-BitLockerVolume -MountPoint 'C:'
if ($BLV.volumeStatus -eq 'FullyDecrypted') {
    Add-BitLockerKeyProtector -MountPoint 'c:' -RecoveryPasswordProtector
    Enable-Bitlocker -MountPoint 'c:' -TpmProtector
}