$ErrorActionPreference='Stop'
$runbook=Join-Path $PSScriptRoot '../Remove-LicensesFromDeletedUsers.ps1'
$env:IDENTITY_ENDPOINT='http://test-identity'; $env:IDENTITY_HEADER='test-header'
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body,$ErrorAction,$TimeoutSec)
    if ($Uri -eq 'http://test-identity') {
        if ($Body.resource -ne 'https://graph.microsoft.com') { throw 'Wrong token resource.' }
        if ($global:scenario -eq 'auth failure') { throw 'Mock auth failure.' }
        if ($global:scenario -eq 'empty token') { return [pscustomobject]@{access_token=''} }
        return [pscustomobject]@{access_token='test-token'}
    }
    if ($Method -ne 'Get') { $global:writes++; throw 'Unexpected directory write.' }
    $global:reads++
    if ($global:scenario -eq 'read failure') { throw 'Mock read failure.' }
    if ($global:scenario -eq 'empty') { return [pscustomobject]@{value=@()} }
    if ($Uri -match 'skiptoken') {
        if ($global:scenario -eq 'page failure') { throw 'Mock page failure.' }
        return [pscustomobject]@{value=@($global:fixture.value | Select-Object -Skip 1)}
    }
    $next='https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$skiptoken=next'
    if ($global:scenario -eq 'repeated page') { $next=$Uri }
    if ($global:scenario -eq 'foreign page') { $next='https://example.test/next' }
    return [pscustomobject]@{value=@($global:fixture.value[0]);'@odata.nextLink'=$next}
}
$passed=0
foreach ($scenario in @('audit','empty','auth failure','empty token','read failure','page failure','repeated page','foreign page')) {
    $global:scenario=$scenario; $global:writes=0; $global:reads=0
    $global:fixture=Get-Content (Join-Path $PSScriptRoot 'fixtures/deleted-users.json') -Raw | ConvertFrom-Json
    $failed=$false
    try { $output=@(& $runbook 3>$null) } catch { $failed=$true }
    $expected=$scenario -notin @('audit','empty')
    if ($failed -ne $expected) { throw "Unexpected result: $scenario" }
    if ($global:writes) { throw 'Directory write attempted.' }
    if ($scenario -eq 'audit' -and ($output[-1] -notmatch '3 deleted users checked; 1 with saved license assignments' -or $global:reads -ne 2)) { throw 'Incomplete audit.' }
    if ($scenario -eq 'empty' -and $output[-1] -notmatch '0 deleted users checked; 0 with saved license assignments') { throw 'Wrong empty audit.' }
    if ($scenario -in @('repeated page','foreign page') -and $global:reads -ne 1) { throw 'Unsafe page fetched.' }
    Write-Output "PASS: deleted-user $scenario"; $passed++
}
Write-Output "$passed deleted-user scenarios passed."
