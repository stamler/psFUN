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
