# This script is written to run in Azure Automation
# Get Stale Guests in Azure AD
# Adapted from https://www.petri.com/guest-account-obsolete-activity

#Office 365 Admin Credentials
$Credential = Get-AutomationPSCredential -Name "Azure Automation Bot"

# Get all guests
Connect-AzureAD -Credential $Credential
$Filter = "UserType eq 'Guest'"
$Guests = Get-AzureADUser -All $true -Filter $Filter

# For each guests, get Unified Audit Log in last 90 days
$StartDate = (Get-Date).AddDays(-90)
$EndDate = (Get-Date)
$AuditRec = 0

# Create output file for report
$Report = [System.Collections.Generic.List[Object]]::new()

#EXOv2
# NB if you don't connect, Search-UnifiedAuditLog will return $null 
# for all users and all guests will be deleted!!!!
Connect-ExchangeOnline -Credential $Credential

ForEach ($G in $Guests) {
    $LastAuditAction = $Null
    $LastAuditRecord = $Null

    # Search for at least 1 audit record for this user
    $Recs = (Search-UnifiedAuditLog -UserIds $G.Mail, $G.UserPrincipalName -Operations UserLoggedIn, SecureLinkUsed, TeamsSessionStarted -StartDate $StartDate -EndDate $EndDate -ResultSize 1)
    If ($Null -ne $Recs.CreationDate) {
       # At least 1 record found
       $LastAuditRecord = $Recs[0].CreationDate
       $LastAuditAction = $Recs[0].Operations
       $AuditRec++
       #Write-Output "Last audit record for $($G.DisplayName) on $LastAuditRecord for $LastAuditAction"
    } Else { 
        Write-Output "No audit records found in the last 90 days for $($G.DisplayName); account created on $($G.RefreshTokensValidFromDateTime)"
        Remove-AzureADUser -ObjectId $G.ObjectId
        Write-Output "Deleted Guest $($G.DisplayName)"
    } 
  
    # Write out report line     
    $ReportLine = [PSCustomObject]@{
        Guest            = $G.Mail
        Name             = $G.DisplayName
        Created          = $G.RefreshTokensValidFromDateTime
        LastConnectOn    = $LastAuditRecord
        LastConnect      = $LastAuditAction
    } 
    $Report.Add($ReportLine)
}

$Active = $AuditRec
#$Report | Export-CSV -NoTypeInformation c:\temp\GuestActivity.csv
Write-Output "$Active of $($Guests.Count) guest accounts are active"
Write-Output "$AuditRec audit records found"
Write-Output "$($Guests.Count - $Active) inactive guests deleted"