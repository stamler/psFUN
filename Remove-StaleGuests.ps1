<#
.SYNOPSIS
Prepare a read-only review of guest accounts with no matching recent audit activity.

.DESCRIPTION
This Azure Automation runbook supports guest access reviews. It replaces the
Azure Automation Bot script that searched audit logs and deleted inactive guests.
The replacement keeps deletion off because missing audit activity alone does
not prove that a guest no longer needs access.

The script uses the UserAutomation system-assigned managed identity and Microsoft
Graph REST calls. It checks the returned identity and audit-read permission,
then reads all guest accounts. It creates or reuses a Microsoft 365 audit query
for 90 days of UserLoggedIn, SecureLinkUsed, and TeamsSessionStarted events.
It waits for success and checks the query's dates, operations, and filters.

Every result page must be read before any guest is reported for review. Activity
is matched against guest object IDs, principal names, mail addresses, and other
mail addresses. Audit actor IDs and membership-prefixed names are also checked.
Guests with matching activity, recent account creation, or recent invitation
state changes are excluded. Missing creation dates are separate review items.

The script rejects incomplete or unexpected queries, empty tenant audit results,
repeated pages, and results above MaxRecords. Transient server errors on reads
have bounded retries. Query creation is not retried because the first request
might already have created a query. The only write is creation of the audit
query; no directory writes or guest deletions are permitted.

.PARAMETER AuditQueryId
Optional existing audit query ID. Its window must be 90 days, end within the
last day, and cover exactly the required operations without extra restrictions.
An empty value creates a new query. A pending query ID is logged for later reuse.

.PARAMETER WaitSeconds
Maximum polling wait for a query to finish. Default: 900 seconds. The limit is
checked between requests; it is not a deadline for the whole run or record reads.

.PARAMETER MaxRecords
Maximum audit records to process. Default: 500000. Exceeding the limit stops the
run before candidate output; it does not turn partial results into a review list.

.EXAMPLE
.\Remove-StaleGuests.ps1
Create a new audit query and report guests for review. Do not delete any guests.

.NOTES
Runtime: Azure Automation Windows PowerShell 5.1; no Exchange Online module needed.
The expected managed identity object ID is specific to TBTE. The token must have
Graph AuditLogsQuery.Read.All plus User.Read.All or User.ReadWrite.All. Azure
supplies IDENTITY_ENDPOINT and IDENTITY_HEADER. Access tokens are never logged.
These three audit operations do not cover every successful sign-in. Add an Entra
last-successful-sign-in check and complete a business review before implementing
automatic deletion. The current script does not include that extra sign-in check.
Schedule parameters are set in Azure. See AUTOMATION.md for deployment details.
#>

param(
    [string]$AuditQueryId = '',
    [ValidateRange(1, 1800)][int]$WaitSeconds = 900,
    [ValidateRange(1, 1000000)][int]$MaxRecords = 500000
)
# Preview only. Never delete a guest because an audit search failed or is incomplete.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$operations=@('UserLoggedIn','SecureLinkUsed','TeamsSessionStarted')
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
$headers=@{Authorization='Bearer '+$identity.access_token}
function Invoke-GuestGraph {
    param([string]$Uri,[string]$Method='Get',$Body=$null)
    if (!$Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)) { throw 'Unexpected Graph URL.' }
    if ($Method -ne 'Get' -and !($Method -eq 'Post' -and $Uri -eq 'https://graph.microsoft.com/v1.0/security/auditLog/queries')) { throw 'This preview does not permit directory writes.' }
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
$guests=@(Get-GuestPages "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$select=id,displayName,userPrincipalName,mail,otherMails,createdDateTime,externalUserState,externalUserStateChangeDateTime&`$top=999")
if (!$guests.Count) { Write-Output 'PREVIEW: 0 guests; no directory changes.'; return }
$root='https://graph.microsoft.com/v1.0/security/auditLog/queries'
if ($AuditQueryId) {
    $query=Invoke-GuestGraph ($root+'/'+[guid]$AuditQueryId)
} else {
    $end=[datetime]::UtcNow
    $query=Invoke-GuestGraph $root Post @{
        displayName='UserAutomation guest cleanup preview '+$end.ToString('s')+'Z'
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
$candidates=0; $recent=0; $active=0; $review=0
foreach ($guest in $guests) {
    $reason=$null
    if (!$guest.createdDateTime) { $reason='Missing account creation date'; $review++ }
    elseif (([datetimeoffset]$guest.createdDateTime).UtcDateTime -gt $start) { $recent++; continue }
    elseif ($guest.externalUserStateChangeDateTime -and ([datetimeoffset]$guest.externalUserStateChangeDateTime).UtcDateTime -gt $start) { $recent++; continue }
    elseif ($last.ContainsKey($guest.id)) { $active++; continue }
    else { $reason='No matching activity in the completed 90-day query; manual review required'; $candidates++ }
    Write-Output ('REVIEW: '+([pscustomobject]@{Id=$guest.id;User=$guest.userPrincipalName;Mail=$guest.mail;Name=$guest.displayName;Created=$guest.createdDateTime;InvitationState=$guest.externalUserState;Reason=$reason} | ConvertTo-Json -Depth 4 -Compress))
}
Write-Output "PREVIEW: $($guests.Count) guests; $active with activity; $recent recent accounts or invitation updates; $candidates inactivity candidates; $review other review items; no directory changes."
