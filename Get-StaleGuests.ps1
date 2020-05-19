# Get Stale Guests in Azure AD
# Adapted from https://www.petri.com/guest-account-obsolete-activity


# Get all guests
#Connect-AzureAD
$Filter = "UserType eq 'Guest'"
$Guests = Get-AzureADUser -All $true -Filter $Filter

# For each guests, get Unified Audit Log in last 90 days
$StartDate = (Get-Date).AddDays(-90)
$EndDate = (Get-Date)
$AuditRec = 0

# Create output file for report
$Report = [System.Collections.Generic.List[Object]]::new()

#EXOv2
#Connect-ExchangeOnline 

ForEach ($G in $Guests) {
    Write-Host $G.DisplayName
    $LastAuditAction = $Null
    $LastAuditRecord = $Null

    # Search for at least 1 audit record for this user
    $Recs = (Search-UnifiedAuditLog -UserIds $G.Mail, $G.UserPrincipalName -Operations UserLoggedIn, SecureLinkUsed, TeamsSessionStarted -StartDate $StartDate -EndDate $EndDate -ResultSize 1)
    If ($Recs.CreationDate -ne $Null) {
       # At least 1 record found
       $LastAuditRecord = $Recs[0].CreationDate
       $LastAuditAction = $Recs[0].Operations
       $AuditRec++
       Write-Host "Last audit record for" $G.DisplayName "on" $LastAuditRecord "for" $LastAuditAction -Foregroundcolor Green
    } Else { 
        Write-Host "No audit records found in the last 90 days for" $G.DisplayName "; account created on" $G.RefreshTokensValidFromDateTime -Foregroundcolor Red
        Remove-AzureADUser -ObjectId $G.ObjectId
        Write-Host "Deleted Guest " $G.DisplayName
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
Write-Host ""
Write-Host "Statistics"
Write-Host "----------"
Write-Host "Guest Accounts          " $Guests.Count
Write-Host "Active Guests           " $Active
Write-Host "Audit Record found      " $AuditRec
Write-Host "Inactive Guests         " ($Guests.Count - $Active)