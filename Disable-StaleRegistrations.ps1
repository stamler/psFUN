param(
    [ValidateSet('Preview', 'Apply')][string]$Mode = 'Preview',
    [ValidateRange(1, 1000)][int]$MaxChanges = 25,
    [string[]]$DeviceIds = @()
)
# Use the Automation account identity. Never use a stored user password.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if (!$env:IDENTITY_ENDPOINT -or !$env:IDENTITY_HEADER) {
    throw 'The Automation managed identity endpoint is unavailable.'
}
$identity = Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT -Headers @{
    'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; Metadata = 'True'
} -ContentType 'application/x-www-form-urlencoded' -Body @{ resource = 'https://graph.microsoft.com/' } -ErrorAction Stop
if (!$identity.access_token) { throw 'Managed identity did not return an access token.' }
$headers = @{ Authorization = 'Bearer ' + $identity.access_token }

function Invoke-DeviceGraph {
    param([string]$Uri, [string]$Method = 'Get', [string]$Body)
    if (!$Uri.StartsWith('https://graph.microsoft.com/v1.0/devices', [StringComparison]::Ordinal)) {
        throw 'Unexpected device API URL.'
    }
    $args = @{ Uri = $Uri; Method = $Method; Headers = $headers; ErrorAction = 'Stop'; TimeoutSec = 60 }
    if ($Body) { $args.Body = $Body; $args.ContentType = 'application/json' }
    # A failed request must fail the job. No success count is printed after a failure.
    Invoke-RestMethod @args
}
function Test-StaleRegistration {
    param($Device, [datetimeoffset]$Cutoff)
    if ($Device.accountEnabled -ne $true -or $Device.trustType -ne 'Workplace') { return $false }
    if ([string]::IsNullOrWhiteSpace($Device.approximateLastSignInDateTime)) { return $false }
    return [datetimeoffset]::Parse($Device.approximateLastSignInDateTime) -le $Cutoff
}
$cutoff = [datetimeoffset]::UtcNow.AddDays(-90)
$select = 'id,displayName,trustType,accountEnabled,approximateLastSignInDateTime,operatingSystem'
$next = 'https://graph.microsoft.com/v1.0/devices?$select=' + $select + '&$top=999'
$devices = @()
$pages = @{}
do {
    if ($pages.ContainsKey($next)) { throw 'Device pagination returned a repeated page.' }
    $pages[$next] = $true
    $page = Invoke-DeviceGraph -Uri $next
    $devices += @($page.value)
    $nextProperty = $page.PSObject.Properties['@odata.nextLink']
    $next = if ($nextProperty) { [string]$nextProperty.Value } else { $null }
} while ($next)
$stale = @($devices | Where-Object { Test-StaleRegistration $_ $cutoff })
$manual = @($stale | Where-Object { $_.operatingSystem -ne 'Windows' })
$candidates = @($stale | Where-Object { $_.operatingSystem -eq 'Windows' -and (!$DeviceIds.Count -or $_.id -in $DeviceIds) })
foreach ($device in $manual) {
    Write-Warning ('Manual device review: ' + ($device | ConvertTo-Json -Compress))
}
foreach ($device in $candidates) {
    Write-Output ('Candidate: ' + ($device | ConvertTo-Json -Compress))
}
if ($Mode -eq 'Preview') {
    Write-Output "PREVIEW: $($devices.Count) devices checked; $($candidates.Count) Windows candidates; $($manual.Count) non-Windows registrations need manual review; no changes."
    return
}
if ($candidates.Count -gt $MaxChanges) {
    throw "Found $($candidates.Count) candidates, above MaxChanges=$MaxChanges. No devices changed. Review a preview before increasing the limit."
}
$changed = 0
$skipped = 0
foreach ($device in $candidates) {
    $uri = 'https://graph.microsoft.com/v1.0/devices/' + [guid]$device.id
    # Check again before each write. A device may have become active since the list was read.
    $current = Invoke-DeviceGraph -Uri ($uri + '?$select=' + $select)
    if (!(Test-StaleRegistration $current $cutoff) -or $current.operatingSystem -ne 'Windows') {
        $skipped++
        Write-Output "Skipped changed registration: $($device.id)"
        continue
    }
    Invoke-DeviceGraph -Uri $uri -Method Patch -Body '{"accountEnabled":false}' | Out-Null
    # Graph reads can lag behind an accepted update. Retry reads, never the write.
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 5 }
        $verified = Invoke-DeviceGraph -Uri ($uri + '?$select=' + $select)
        if ($verified.accountEnabled -eq $false) { break }
    }
    if ($verified.accountEnabled -ne $false) { throw "Could not verify disabled registration: $($device.id)" }
    $changed++
    Write-Output "Disabled and verified registration: $($device.id) ($($device.displayName))"
}
Write-Output "COMPLETE: $changed Windows registrations disabled and verified; $skipped skipped after recheck; $($manual.Count) non-Windows registrations need manual review."
