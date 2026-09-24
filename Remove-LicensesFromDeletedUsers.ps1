<#
.SYNOPSIS
Audit saved license assignments on deleted Microsoft Entra users.

.DESCRIPTION
This Azure Automation runbook preserves a check on deleted-user licensing
without the old restore, remove-license, and delete cycle. Microsoft 365 returns
a license seat when its user is deleted. Restoring that user to remove a saved
assignment is therefore not part of this audit.

The script uses the UserAutomation system-assigned managed identity and
Microsoft Graph REST calls instead of the Azure Automation Bot user credential.
It reads every page of deleted user objects, then reports each user whose
assignedLicenses collection still contains a saved assignment. Output includes
the user object ID, principal name, deletion date, and saved SKU IDs. A final
summary gives the number checked and the number that need review.

This is a read-only directory audit, despite the retained script name. It never
restores a user, assigns or removes a license, or deletes an account. A saved
assignment does not prove that a seat is consumed. Review such records before
deciding whether any action is needed.

.EXAMPLE
.\Remove-LicensesFromDeletedUsers.ps1
Report saved assignments on deleted users without changing the directory.

.NOTES
Runtime: Azure Automation Windows PowerShell 5.1; no MSOnline module required.
The deployed identity has Graph User.Read.All and User.ReadWrite.All. This
script uses only user reads. Azure supplies IDENTITY_ENDPOINT and IDENTITY_HEADER.
Authentication errors, failed reads, repeated pages, or unexpected page URLs
stop the job. All pages must be read before assignment review output is produced.
There are no script parameters. Scheduling is set in Azure.
See AUTOMATION.md for deployment details.
#>

# Microsoft 365 returns a license seat when its user is deleted.
# Audit saved assignments without restoring accounts or changing their retention period.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (!$env:IDENTITY_ENDPOINT -or !$env:IDENTITY_HEADER) { throw 'Automation managed identity endpoint is unavailable.' }
$identity = Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT -Headers @{
    'X-IDENTITY-HEADER'=$env:IDENTITY_HEADER; Metadata='True'
} -ContentType 'application/x-www-form-urlencoded' -Body @{resource='https://graph.microsoft.com'} -ErrorAction Stop
if (!$identity.access_token) { throw 'Managed identity returned no access token.' }
$headers = @{Authorization='Bearer '+$identity.access_token}
$uri='https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$select=id,userPrincipalName,deletedDateTime,assignedLicenses&$top=999'
$seen=@{}
$users=@()
while ($uri) {
    if (!$uri.StartsWith('https://graph.microsoft.com/v1.0/', [StringComparison]::Ordinal)) { throw 'Unexpected Graph URL.' }
    if ($seen.ContainsKey($uri)) { throw 'Repeated Graph page.' }
    $seen[$uri]=$true
    $page=Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 60 -ErrorAction Stop
    foreach ($user in $page.value) { $users+=$user }
    $next=$page.PSObject.Properties['@odata.nextLink']
    $uri=if ($next) { [string]$next.Value } else { $null }
}
$flagged=0
foreach ($user in $users) {
    $saved=@($user.assignedLicenses | Where-Object { $null -ne $_ })
    if ($saved.Count) {
        $flagged++
        $record=[pscustomobject]@{
            Id=$user.id; User=$user.userPrincipalName; Deleted=$user.deletedDateTime
            SavedSkuIds=@($saved | ForEach-Object { $_.skuId })
        }
        Write-Warning ('REVIEW: Deleted user has saved license assignments. This does not establish that seats are consumed. '+($record | ConvertTo-Json -Depth 4 -Compress))
    }
}
Write-Output "COMPLETE: $($users.Count) deleted users checked; $flagged with saved license assignments; no users restored or changed."
