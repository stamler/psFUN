<#  
.SYNOPSIS 
    Script that assigns Office 365 licenses based on Group membership..
.NOTES 
    The script are provided “AS IS” with no guarantees, no warranties, and they confer no rights.
    https://tech.ligthartnet.nl/assign-microsoft-office-365-licenses-through-azure-automation/

    TODO: BUG: Set-MsolUserLicense on Line 124 fails if the user has multiple
    licenses already assigned. The thrown error says the license is invalid, 
    it’s really not. It throws because that user already had that license set to add. 
#>

#Office 365 Admin Credentials
$Credential = Get-AutomationPSCredential -Name "License Automation Bot"

#Connect to Office 365 
Connect-MsolService -Credential $Credential

$LicenseOptions = New-MsolLicenseOptions -AccountSkuId "tbte:O365_BUSINESS_PREMIUM" #-DisabledPlans "SWAY","KAIZALA_O365_P2"

$Licenses = @{
      'Microsoft365BusinessStandard' = @{ 
            LicenseSKU = 'tbte:O365_BUSINESS_PREMIUM'
            Group = 'TBTE_Desktop_Software'
      }
      'Microsoft365BusinessBasic' = @{
            LicenseSKU = 'tbte:O365_BUSINESS_ESSENTIALS'
            Group = 'TBTE_Mobile_Software'
      }
}
    
$UsageLocation = 'CA'
    
#Get all currently licensed users and put them in a custom object
$LicensedUserDetails = Get-MsolUser -All | Where-Object {$_.IsLicensed -eq 'True'} | ForEach-Object {
 [pscustomobject]@{
            UserPrincipalName = $_.UserPrincipalName
            License = $_.Licenses.AccountSkuId
            }
 }
    
#Create array for users to change or delete
$UsersToChangeOrDelete = @()
    
foreach ($license in $Licenses.Keys) {
      
  #Get current group name and ObjectID from Hashtable
  $GroupName = $Licenses[$license].Group
  $GroupID = (Get-MsolGroup -All | Where-Object {$_.DisplayName -eq $GroupName}).ObjectId
  $AccountSKU = Get-MsolAccountSku | Where-Object {$_.AccountSKUID -eq $Licenses[$license].LicenseSKU}
    
  Write-Output "Checking for unlicensed $license users in group $GroupName with ObjectGuid $GroupID..."
  #Get all members of the group in current scope
  $GroupMembers = (Get-MsolGroupMember -GroupObjectId $GroupID -All).EmailAddress
  #Get all already licensed users in current scope
  $ActiveUsers = ($LicensedUserDetails | Where-Object {$_.License -eq $licenses[$license].LicenseSKU}).UserPrincipalName 
  $UsersToHandle = ''
    
    if ($GroupMembers) {  
        if ($ActiveUsers) {  
            #Compare $Groupmembers and $Activeusers
            #Users which are in the group but not licensed, will be added
            #Users licensed, but not, will be evaluated for deletion or change of license 
            $UsersToHandle = Compare-Object -ReferenceObject $GroupMembers -DifferenceObject $ActiveUsers -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            $UsersToAdd = ($UsersToHandle | Where-Object {$_.SideIndicator -eq '<='}).InputObject
            $UsersToChangeOrDelete += ($UsersToHandle | Where-Object {$_.SideIndicator -eq '=>'}).InputObject  
        } else {  
            #No licenses currently assigned for the license in scope, assign licenses to all group members.
            $UsersToAdd = $GroupMembers
        }
    
    } else {  
      Write-Warning  "Group $GroupName is empty - will process removal or move of all users with license $($AccountSKU.AccountSkuId)"
      #If no users are a member in the group, add them for deletion or change of license.
      $UsersToChangeOrDelete += $ActiveUsers
    }
            
  #Check the amount of licenses left...
  if ($AccountSKU.ActiveUnits - $AccountSKU.consumedunits -lt $UsersToAdd.Count) { 
        Write-Warning 'Not enough licenses for all users, please remove user licenses or buy more licenses'
  }
           
     foreach ($User in $UsersToAdd){
    
        #Process all users for license assignment, if not already licensed with the SKU in order.  
          if ((Get-MsolUser -UserPrincipalName $User).Licenses.AccountSkuId -notcontains $AccountSku.AccountSkuId) {
            try {  
                  #Assign UsageLocation and License.
                  Set-MsolUser -UserPrincipalName $User -UsageLocation $UsageLocation -ErrorAction Stop -WarningAction Stop
                  Set-MsolUserLicense -UserPrincipalName $User -AddLicenses $AccountSKU.AccountSkuId -LicenseOptions $LicenseOptions -ErrorAction Stop -WarningAction Stop
                  Write-Output "SUCCESS: Licensed $User with $license"
            } catch {  
                  Write-Warning "Error when licensing $User"
    
            }
            
          }  
     }
}
    
#Process users for change or deletion
if ($null -ne $UsersToChangeOrDelete) {
        foreach ($User in $UsersToChangeOrDelete) {
          if ($null -ne $user) {
    
            #Fetch users old license for later usage
            $OldLicense = ($LicensedUserDetails | Where-Object {$_.UserPrincipalName -eq $User}).License
                 
             #Loop through to check if the user group assignment has been changed, and put the old and the new license in a custom object.
             #Only one license group per user is currently supported.
             $ChangeLicense = $Licenses.Keys | ForEach-Object {
                  $GroupName = $Licenses[$_].Group
                  if (Get-MsolGroupMember -All -GroupObjectId (Get-MsolGroup -All | Where-Object {$_.DisplayName -eq $GroupName}).ObjectId | Where-Object {$_.EmailAddress -eq $User}) {
                     [pscustomobject]@{
                        OldLicense = $OldLicense
                        NewLicense = $Licenses[$_].LicenseSKU
                     }
                  } 
    
              }
    
              if ($ChangeLicense) {
                    #The user were assigned to another group, switch license to the new one.
                    try {  
                          Set-MsolUserLicense -UserPrincipalName $User -RemoveLicenses $ChangeLicense.OldLicense -AddLicenses $ChangeLicense.NewLicense -LicenseOptions $LicenseOptions -ErrorAction Stop -WarningAction Stop
                          Write-Output "SUCCESS: Changed license for user $User from $($ChangeLicense.OldLicense) to $($ChangeLicense.NewLicense)"
                    } catch {  
                          Write-Warning "Error when changing license on $User`r`n$_"
                    }
                      
              } else {  
                               
                    #The user is no longer a member of any license group, remove license
                    Write-Warning "$User is not a member of any group, license will be removed... "
                    try {  
                          Set-MsolUserLicense -UserPrincipalName $User -RemoveLicenses $OldLicense -ErrorAction Stop -WarningAction Stop
                          Write-Output "SUCCESS: Removed $OldLicense for $User"
                    } catch {  
                          Write-Warning "Error when removing license on user`r`n$_"
                    }
              }
         }
    }
}