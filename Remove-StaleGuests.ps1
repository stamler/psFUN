<#
.SYNOPSIS
Delete stale guest accounts after checking audit activity and successful sign-ins.

.DESCRIPTION
This Azure Automation runbook removes guest access that has not been used for
90 days. It replaces the Azure Automation Bot password with the UserAutomation
system-assigned managed identity and Microsoft Graph REST calls.

The script reads all guests and their signInActivity. A successful interactive
or non-interactive sign-in within 90 days always excludes the guest. Recent
sign-in attempts also exclude the guest as a precaution. Missing or invalid
successful-sign-in data requires manual review; it never proves inactivity.
Guests created or invited within the period are also excluded.

A completed Microsoft 365 audit query adds protection for UserLoggedIn,
SecureLinkUsed, and TeamsSessionStarted activity. All result pages must be read
before any candidate is selected. Failed queries, unexpected filters, empty
tenant results, invalid records, and pagination failures stop the job.

Preview reports the plan without directory writes. Apply reads each selected
guest again, checks that its identity and invitation details have not changed,
and checks sign-in activity again immediately before deletion. It deletes only
guest user objects, then verifies each object in Deleted users. No permanent
purge is performed. A failure stops the run; earlier deletes are not rolled back.

.PARAMETER Mode
Preview reports candidates. Apply deletes eligible guests. Default: Preview.

.PARAMETER MaxDeletions
Maximum guests to delete per run. Default: 10. Select the oldest accounts first
and leave any remaining candidates for a later run. Skipped accounts do not cause
additional candidates beyond the selected batch to be processed.

.PARAMETER AuditQueryId
Optional query to reuse in Preview. Apply must create a fresh query. Reused
queries must cover 90 days, end within the last day, and have the required filters.

.PARAMETER WaitSeconds
Maximum query polling wait. Default: 900 seconds. Checked between requests; this
is not a deadline for record downloads or the whole run.

.PARAMETER MaxRecords
Maximum audit records to read. Default: 500000. Exceeding the limit stops the run
before candidate output or deletion.

.EXAMPLE
.\Remove-StaleGuests.ps1 -Mode Preview
Report eligible guests and accounts that need manual review.

.EXAMPLE
.\Remove-StaleGuests.ps1 -Mode Apply -MaxDeletions 10
Delete and verify up to ten eligible guests using a new audit query.

.NOTES
Runtime: Azure Automation Windows PowerShell 5.1; no AzureAD or Exchange module.
The expected managed identity object ID is specific to TBTE. The identity needs
Graph AuditLogsQuery.Read.All, AuditLog.Read.All, and User.Read.All or
User.ReadWrite.All. Apply requires User.ReadWrite.All. Azure supplies the identity
endpoint and header. Access tokens are never logged.
Sign-in and audit data can arrive late. These checks use Microsoft's reported
data and cannot eliminate the delay between a real event and its appearance.
Unknown sign-in history is left for review, including unredeemed invitations.
Schedule settings are in Azure; source edits do not change them. See AUTOMATION.md.
#>

param(
    [ValidateSet('Preview', 'Apply')][string]$Mode = 'Preview',
    [ValidateRange(1, 100)][int]$MaxDeletions = 10,
    [string]$AuditQueryId = '',
    [ValidateRange(1, 1800)][int]$WaitSeconds = 900,
    [ValidateRange(1, 1000000)][int]$MaxRecords = 500000
)
# A failed or incomplete activity check must never permit deletion.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$operations=@('UserLoggedIn','SecureLinkUsed','TeamsSessionStarted')
if ($Mode -eq 'Apply' -and $AuditQueryId) { throw 'Apply requires a new audit query.' }
$deleteTarget=''
if (!$env:IDENTITY_ENDPOINT -or !$env:IDENTITY_HEADER) { throw 'Managed identity endpoint is unavailable.' }
$identity=Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT -Headers @{
    'X-IDENTITY-HEADER'=$env:IDENTITY_HEADER; Metadata='True'
} -ContentType 'application/x-www-form-urlencoded' -Body @{resource='00000003-0000-0000-c000-000000000000'} -ErrorAction Stop
if (!$identity.access_token) { throw 'Managed identity returned no token.' }
# Check only our identity and permissions. Never log the token.
$payload=$identity.access_token.Split('.')[1].Replace('-','+').Replace('_','/')
$payload=$payload.PadRight($payload.Length+((4-$payload.Length%4)%4),'=')
$claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
if ($claims.oid -ne '6959416e-404d-4485-a5af-e23264eb240d') { throw 'Unexpected managed identity.' }
if ('AuditLogsQuery.Read.All' -notin $claims.roles) { throw 'Audit-read permission has not reached the managed-identity token.' }
if ('User.Read.All' -notin $claims.roles -and 'User.ReadWrite.All' -notin $claims.roles) { throw 'User-read permission is missing.' }
if ('AuditLog.Read.All' -notin $claims.roles) { throw 'Sign-in-read permission is missing from the managed-identity token.' }
if ($Mode -eq 'Apply' -and 'User.ReadWrite.All' -notin $claims.roles) { throw 'Guest deletion permission is missing.' }
$headers=@{Authorization='Bearer '+$identity.access_token}
function Invoke-GuestGraph {
    param([string]$Uri,[string]$Method='Get',$Body=$null)
    if (!$Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)) { throw 'Unexpected Graph URL.' }
    $createQuery=($Method -eq 'Post' -and $Uri -eq 'https://graph.microsoft.com/v1.0/security/auditLog/queries')
    $deleteGuest=($Mode -eq 'Apply' -and $Method -eq 'Delete' -and $deleteTarget -and $Uri -ceq $deleteTarget)
    if ($Method -ne 'Get' -and !$createQuery -and !$deleteGuest) { throw 'Unexpected directory write.' }
    $request=@{Uri=$Uri;Method=$Method;Headers=$headers;TimeoutSec=60;ErrorAction='Stop'}
    if ($null -ne $Body) { $request.Body=ConvertTo-Json -InputObject $Body -Depth 8 -Compress; $request.ContentType='application/json' }
    for ($attempt=0; $attempt -lt 4; $attempt++) {
        try { return (Invoke-RestMethod @request) }
        catch {
            # Retry transient reads only. A failed POST might already have created a query.
            $responseProperty=$_.Exception.PSObject.Properties['Response']
            $response=if ($responseProperty) { $responseProperty.Value } else { $null }
            $code=if ($response) { [int]$response.StatusCode } else { 0 }
            if ($Method -ne 'Get' -or $attempt -ge 3 -or $code -notin @(500,502,503,504)) { throw }
            $delay=@(5,15,30)[$attempt]
            if ($response.Headers['Retry-After']) {
                $requested=0
                if (![int]::TryParse([string]$response.Headers['Retry-After'],[ref]$requested) -or $requested -gt 60) { throw }
                $delay=[Math]::Max($delay,$requested)
            }
            Write-Warning "Audit read returned HTTP $code. Retry $($attempt+1) in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}
function Get-GuestPages {
    param([string]$Uri)
    $seen=@{}
    while ($Uri) {
        if ($seen.ContainsKey($Uri)) { throw 'Repeated Graph page.' }
        $seen[$Uri]=$true
        $page=Invoke-GuestGraph $Uri
        foreach ($item in $page.value) { $item }
        $next=$page.PSObject.Properties['@odata.nextLink']
        $Uri=if ($next) { [string]$next.Value } else { $null }
    }
}
function Get-OptionalValue {
    param($Object,[string]$Name)
    if ($null -eq $Object) { return $null }
    $property=$Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}
function Get-IdentityKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $key=$Value.Trim().ToLowerInvariant()
    if ($key.StartsWith('i:0#.f|membership|')) { $key=$key.Substring('i:0#.f|membership|'.Length) }
    return $key
}
$guestSelect='id,userType,displayName,userPrincipalName,mail,otherMails,createdDateTime,externalUserState,externalUserStateChangeDateTime,signInActivity'
$guests=@(Get-GuestPages ("https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$select="+$guestSelect+'&$top=500'))
$seenGuests=@{}
foreach ($guest in $guests) {
    $id=[string][guid]$guest.id
    if ($seenGuests.ContainsKey($id)) { throw 'Duplicate guest in directory results.' }
    if ($guest.userType -ne 'Guest') { throw 'Non-guest in guest directory results.' }
    $seenGuests[$id]=$true
}
if (!$guests.Count) { Write-Output ($Mode.ToUpper()+': 0 guests; no directory changes.'); return }
$root='https://graph.microsoft.com/v1.0/security/auditLog/queries'
if ($AuditQueryId) {
    $query=Invoke-GuestGraph ($root+'/'+[guid]$AuditQueryId)
} else {
    $end=[datetime]::UtcNow
    $query=Invoke-GuestGraph $root Post @{
        displayName='UserAutomation guest cleanup '+$end.ToString('s')+'Z'
        filterStartDateTime=$end.AddDays(-90).ToString('o'); filterEndDateTime=$end.ToString('o')
        operationFilters=$operations
    }
}
$queryId=[string][guid]$query.id
Write-Output ('Audit query: '+$queryId)
$started=[datetime]::UtcNow
while ($query.status -in @('notStarted','running')) {
    if (([datetime]::UtcNow-$started).TotalSeconds -ge $WaitSeconds) { throw "Audit query is still pending: $queryId. No inactivity decision was made." }
    Start-Sleep -Seconds 15
    $query=Invoke-GuestGraph ($root+'/'+$queryId)
}
if ($query.status -ne 'succeeded') { throw "Audit query did not succeed: $($query.status). No inactivity decision was made." }
$start=([datetimeoffset]$query.filterStartDateTime).UtcDateTime
$end=([datetimeoffset]$query.filterEndDateTime).UtcDateTime
if (($end-$start).TotalDays -lt 89.99 -or ($end-$start).TotalDays -gt 90.01 -or $end -lt [datetime]::UtcNow.AddDays(-1) -or $end -gt [datetime]::UtcNow.AddMinutes(5)) { throw 'Audit query has an unexpected time window.' }
if ((($query.operationFilters | Sort-Object) -join ',') -ne (($operations | Sort-Object) -join ',')) { throw 'Audit query does not cover the required operations.' }
foreach ($field in @('recordTypeFilters','keywordFilter','serviceFilter','serviceFilters','userPrincipalNameFilters','ipAddressFilters','objectIdFilters','administrativeUnitIdFilters')) {
    $value=Get-OptionalValue $query $field
    if (@($value | Where-Object { $_ }).Count) { throw "Audit query has an unexpected restriction: $field" }
}
$matches=@{}
foreach ($guest in $guests) {
    foreach ($value in @($guest.id,$guest.userPrincipalName,$guest.mail)+@($guest.otherMails)) {
        $key=Get-IdentityKey $value
        if (!$key) { continue }
        if (!$matches.ContainsKey($key)) { $matches[$key]=@() }
        if ($guest.id -notin $matches[$key]) { $matches[$key]+=$guest.id }
    }
}
$last=@{}; $count=0; $operationCounts=@{}; $firstRecord=$null
foreach ($operation in $operations) { $operationCounts[$operation]=0 }
# Finish all pages before reporting any guest as a candidate.
Get-GuestPages ($root+'/'+$queryId+'/records?$top=1000') | ForEach-Object {
    $record=$_; $count++
    if ($count -gt $MaxRecords) { throw 'Audit record limit reached. No inactivity decision was made.' }
    if ($record.operation -notin $operations) { throw 'Unexpected operation in audit results.' }
    $time=([datetimeoffset]$record.createdDateTime).UtcDateTime
    if ($time -lt $start -or $time -gt $end) { throw 'Audit result is outside the requested period.' }
    if ($null -eq $firstRecord -or $time -lt $firstRecord) { $firstRecord=$time }
    $operationCounts[$record.operation]++
    $keys=@((Get-OptionalValue $record 'userId'),(Get-OptionalValue $record 'userPrincipalName'))
    $data=Get-OptionalValue $record 'auditData'
    $keys+=@((Get-OptionalValue $data 'UserId'),(Get-OptionalValue $data 'UserKey'))
    foreach ($actor in @(Get-OptionalValue $data 'Actor')) { $keys+=@(Get-OptionalValue $actor 'ID') }
    foreach ($value in $keys) {
        $key=Get-IdentityKey $value
        if ($key -and $matches.ContainsKey($key)) {
            foreach ($id in $matches[$key]) {
                if (!$last.ContainsKey($id) -or $time -gt $last[$id]) { $last[$id]=$time }
            }
        }
    }
}
Write-Output ('Audit coverage: '+(@{Records=$count;Operations=$operationCounts;FirstRecord=$firstRecord;Start=$start;End=$end} | ConvertTo-Json -Depth 4 -Compress))
if (!$count) { throw 'No audit records returned for the tenant. No inactivity decision was made.' }
function Get-GuestDecision {
    param($Guest, [datetime]$Cutoff)
    if ($Guest.userType -ne 'Guest') { return 'Review: Not a guest' }
    $created=Get-OptionalValue $Guest 'createdDateTime'
    if (!$created) { return 'Review: Missing account creation date' }
    try { $createdTime=([datetimeoffset]::Parse($created)).UtcDateTime }
    catch { return 'Review: Invalid account creation date' }
    if ($createdTime -ge $Cutoff) { return 'Recent' }
    $invited=Get-OptionalValue $Guest 'externalUserStateChangeDateTime'
    if ($invited) {
        try { $invitedTime=([datetimeoffset]::Parse($invited)).UtcDateTime }
        catch { return 'Review: Invalid invitation date' }
        if ($invitedTime -ge $Cutoff) { return 'Recent' }
    }
    if ($last.ContainsKey($Guest.id)) { return 'Active' }
    $activity=Get-OptionalValue $Guest 'signInActivity'
    $success=Get-OptionalValue $activity 'lastSuccessfulSignInDateTime'
    if (!$success) { return 'Review: No known successful sign-in date' }
    try { $successTime=([datetimeoffset]::Parse($success)).UtcDateTime }
    catch { return 'Review: Invalid successful sign-in date' }
    if ($successTime -ge $Cutoff) { return 'Active' }
    # A recent failed attempt can also protect the account; it cannot justify deletion.
    foreach ($field in @('lastSignInDateTime','lastNonInteractiveSignInDateTime')) {
        $attempt=Get-OptionalValue $activity $field
        if (!$attempt) { continue }
        try { $attemptTime=([datetimeoffset]::Parse($attempt)).UtcDateTime }
        catch { return 'Review: Invalid sign-in attempt date' }
        if ($attemptTime -ge $Cutoff) { return 'Active' }
    }
    return 'Candidate'
}
function Get-GuestIdentityKey {
    param($Guest)
    # A changed invitation or alias requires a new run and a new audit match.
    return (@($Guest.id,$Guest.userType,$Guest.userPrincipalName,$Guest.mail,
        $Guest.createdDateTime,$Guest.externalUserState,$Guest.externalUserStateChangeDateTime,
        (@($Guest.otherMails | Sort-Object) -join ',')) | ConvertTo-Json -Compress)
}
$candidates=@(); $recent=0; $active=0; $review=0
foreach ($guest in $guests) {
    $decision=Get-GuestDecision $guest $start
    if ($decision -eq 'Recent') { $recent++; continue }
    if ($decision -eq 'Active') { $active++; continue }
    if ($decision -eq 'Candidate') { $candidates+=$guest } else { $review++ }
    $label=if ($decision -eq 'Candidate') { 'CANDIDATE: ' } else { 'REVIEW: ' }
    Write-Output ($label+([pscustomobject]@{
        Id=$guest.id;User=$guest.userPrincipalName;Mail=$guest.mail;Name=$guest.displayName
        Created=$guest.createdDateTime;InvitationState=$guest.externalUserState;Reason=$decision
        LastSuccessfulSignIn=(Get-OptionalValue (Get-OptionalValue $guest 'signInActivity') 'lastSuccessfulSignInDateTime')
    } | ConvertTo-Json -Depth 4 -Compress))
}
Write-Output "PLAN: $($guests.Count) guests; $active with activity; $recent recent accounts or invitation updates; $($candidates.Count) deletion candidates; $review review items."
if ($Mode -eq 'Preview') { Write-Output 'PREVIEW: No directory changes.'; return }
$batch=@($candidates | Sort-Object createdDateTime,id | Select-Object -First $MaxDeletions)
$deferred=$candidates.Count-$batch.Count
$deleted=0; $skipped=0
foreach ($guest in $batch) {
    $id=[string][guid]$guest.id
    $uri='https://graph.microsoft.com/v1.0/users/'+$id
    # Use a filtered list because signInActivity is a directory reporting property.
    $fresh=@(Get-GuestPages ("https://graph.microsoft.com/v1.0/users?`$filter=id eq '$id'&`$select="+$guestSelect+'&$top=500'))
    if ($fresh.Count -eq 0) { $skipped++; Write-Output "Skipped absent guest: $id"; continue }
    if ($fresh.Count -ne 1 -or $fresh[0].id -ne $id) { throw "Unexpected guest recheck result: $id" }
    $decision=Get-GuestDecision $fresh[0] $start
    if ($decision -ne 'Candidate' -or (Get-GuestIdentityKey $guest) -cne (Get-GuestIdentityKey $fresh[0])) {
        $skipped++; Write-Output "Skipped changed or protected guest: $id ($decision)"; continue
    }
    # Only this exact, rechecked object can be passed to the DELETE helper.
    $deleteTarget=$uri
    try { Invoke-GuestGraph $uri Delete | Out-Null }
    finally { $deleteTarget='' }
    $verified=$false
    for ($attempt=0; $attempt -lt 6; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 5 }
        try {
            $removed=Invoke-GuestGraph ('https://graph.microsoft.com/v1.0/directory/deletedItems/'+$id+'?$select=id')
            if ($removed.id -ne $id) { throw "Unexpected deleted user ID: $id" }
            $verified=$true; break
        } catch {
            $response=Get-OptionalValue $_.Exception 'Response'
            if (!$response -or [int]$response.StatusCode -ne 404) { throw }
        }
    }
    if (!$verified) { throw "Could not verify guest deletion: $id" }
    $deleted++
    Write-Output "Deleted and verified guest: $id ($($guest.userPrincipalName))"
}
Write-Output "COMPLETE: $deleted guests deleted and verified; $skipped skipped after recheck; $deferred deferred by MaxDeletions=$MaxDeletions; $review require review."
