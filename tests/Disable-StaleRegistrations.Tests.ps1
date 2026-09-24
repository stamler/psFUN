$ErrorActionPreference = 'Stop'
$runbook = Join-Path $PSScriptRoot '../Disable-StaleRegistrations.ps1'
$env:IDENTITY_ENDPOINT = 'http://test-identity'
$env:IDENTITY_HEADER = 'test-header'
function New-Device($id, $days=100, $os='Windows', $trust='Workplace', $enabled=$true) {
    [pscustomobject]@{ id=$id; displayName='Test'; approximateLastSignInDateTime=[datetimeoffset]::UtcNow.AddDays(-$days).ToString('o'); operatingSystem=$os; trustType=$trust; accountEnabled=$enabled }
}
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body,$ErrorAction,$TimeoutSec)
    if ($Uri -eq 'http://test-identity') {
        if ($global:case -eq 'auth failure') { throw 'Test authentication failure' }
        return [pscustomobject]@{access_token='test-token'}
    }
    if ($Uri -match '/devices\?') {
        if ($global:case -eq 'list failure') { throw 'Test list failure' }
        return [pscustomobject]@{value=@($global:inputDevices[0]); '@odata.nextLink'='https://graph.microsoft.com/v1.0/devices?$skiptoken=test'}
    }
    if ($Uri -match 'skiptoken') { throw 'Unexpected paging order' }
    if ($Method -eq 'Patch') {
        if ($global:case -eq 'patch failure') { throw 'Test patch failure' }
        $global:patches++
        if ($Body -ne '{"accountEnabled":false}') { throw 'Wrong write body' }
        $global:disabled = $true
        return
    }
    $global:reads++
    $d=New-Device '00000000-0000-0000-0000-000000000001'
    if ($global:case -eq 'fresh recheck') { $d.approximateLastSignInDateTime=[datetimeoffset]::UtcNow.ToString('o') }
    if ($global:disabled -and $global:case -ne 'verify failure' -and !($global:case -eq 'delayed verification' -and $global:reads -lt 4)) { $d.accountEnabled=$false }
    return $d
}
# Route the second page separately from the first page.
$originalMock = ${function:Invoke-RestMethod}
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body,$ErrorAction,$TimeoutSec)
    if ($Uri -match 'skiptoken') {
        if ($global:case -eq 'page failure') { throw 'Test second page failure' }
        return [pscustomobject]@{value=@($global:inputDevices | Select-Object -Skip 1)}
    }
    & $originalMock @PSBoundParameters
}
function Start-Sleep { param($Seconds) $global:sleeps++ }
$passed=0
foreach ($case in @('preview','apply','delayed verification','fresh recheck','auth failure','list failure','page failure','patch failure','verify failure','limit')) {
    $global:case=$case; $global:patches=0; $global:reads=0; $global:disabled=$false; $global:sleeps=0
    $nullDate=New-Device '00000000-0000-0000-0000-000000000008'; $nullDate.approximateLastSignInDateTime=$null
    $global:inputDevices=@(
        (New-Device '00000000-0000-0000-0000-000000000001'),
        (New-Device '00000000-0000-0000-0000-000000000002' 10),
        (New-Device '00000000-0000-0000-0000-000000000003' 100 'iOS'),
        (New-Device '00000000-0000-0000-0000-000000000004' 100 'Windows' 'AzureAd'),
        (New-Device '00000000-0000-0000-0000-000000000005' 100 'Windows' 'ServerAd'),
        (New-Device '00000000-0000-0000-0000-000000000006' 100 'Windows' 'Workplace' $false),
        (New-Device '00000000-0000-0000-0000-000000000007' 89), $nullDate
    )
    if ($case -eq 'limit') { $global:inputDevices += New-Device '00000000-0000-0000-0000-000000000009' }
    $mode=if($case -eq 'preview'){'Preview'}else{'Apply'}
    $failed=$false; $result=@()
    try { $result=@(& $runbook -Mode $mode -MaxChanges 1 -WarningAction SilentlyContinue) } catch { $failed=$true; $failureText = $_.ToString() }
    $expectFailure=$case -in @('auth failure','list failure','page failure','patch failure','verify failure','limit')
    if ($failed -ne $expectFailure) { throw "Unexpected failure state for $case : $failed ($failureText)" }
    $expectedWrites=if($case -in @('apply','delayed verification','verify failure')){1}else{0}
    if ($global:patches -ne $expectedWrites) { throw "Wrong write count for $case : $global:patches" }
    if ($case -eq 'preview' -and ($result[-1] -notmatch '8 devices checked; 1 Windows candidates; 1 non-Windows')) { throw "Wrong preview: $($result[-1])" }
    if ($case -eq 'delayed verification' -and $global:sleeps -ne 2) { throw 'Delayed read was not retried' }
    if ($case -eq 'verify failure' -and $global:sleeps -ne 11) { throw 'Verification retry limit failed' }
    Write-Output "PASS: $case"; $passed++
}
Write-Output "$passed scenarios passed."
