$ErrorActionPreference='Stop'
$runbook=Join-Path $PSScriptRoot '../Remove-StaleGuests.ps1'
$env:IDENTITY_ENDPOINT='http://test-identity';$env:IDENTITY_HEADER='test-header'
function Start-Sleep { param($Seconds) if($global:scenario -eq 'pending'){[Threading.Thread]::Sleep(1100)} }
Add-Type -TypeDefinition @'
using System;
using System.Collections;
public class GuestMockResponse { public int StatusCode; public Hashtable Headers = new Hashtable(); }
public class GuestMockHttpException : Exception {
    public GuestMockResponse Response;
    public GuestMockHttpException(int code) : base("Mock HTTP error") { Response = new GuestMockResponse { StatusCode = code }; }
}
'@
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body,$ErrorAction,$TimeoutSec)
    if ($Uri -eq 'http://test-identity') {
        if ($Body.resource -ne '00000003-0000-0000-c000-000000000000') { throw 'Wrong Graph resource.' }
        if ($global:scenario -eq 'auth failure') { throw 'Mock auth failure.' }
        if ($global:scenario -eq 'empty token') { return [pscustomobject]@{access_token=''} }
        return [pscustomobject]@{access_token=$global:token}
    }
    if ($Method -ne 'Get' -and !($Method -eq 'Post' -and $Uri -eq 'https://graph.microsoft.com/v1.0/security/auditLog/queries')) { $global:writes++; throw 'Directory write attempted.' }
    if ($Uri -match '/users\?') {
        if($global:scenario -eq 'user failure'){throw 'Mock user failure.'}
        if($global:scenario -eq 'empty guests'){return [pscustomobject]@{value=@()}}
        return [pscustomobject]@{value=@($global:fixture.guests)}
    }
    if ($Method -eq 'Post') {
        $global:queries++
        if($global:scenario -eq 'transient create failure'){throw [GuestMockHttpException]::new(504)}
        if($global:scenario -eq 'query create failure'){throw 'Mock create failure.'}
        $global:query=$Body|ConvertFrom-Json
        $global:query|Add-Member id '11111111-1111-1111-1111-111111111111'
        $global:query|Add-Member status 'succeeded'
        # Fixture time offsets follow the real query window to keep boundary tests stable.
        if($global:scenario -eq 'pending'){$global:query.status='running'}
        if($global:scenario -eq 'query failed'){$global:query.status='failed'}
        if($global:scenario -eq 'wrong window'){$global:query.filterStartDateTime=([datetime]::UtcNow.AddDays(-30)).ToString('o')}
        if($global:scenario -eq 'wrong operations'){$global:query.operationFilters=@('UserLoggedIn')}
        if($global:scenario -eq 'restricted query'){$global:query|Add-Member userPrincipalNameFilters @('employee@example.test')}
        return $global:query
    }
    if ($Uri -match '/records') {
        $global:recordReads++
        if(($global:scenario -eq 'transient read' -and $global:recordReads -eq 1) -or $global:scenario -eq 'persistent gateway failure'){throw [GuestMockHttpException]::new(504)}
        if($global:scenario -eq 'forbidden read'){throw [GuestMockHttpException]::new(403)}
        if($global:scenario -eq 'empty records'){return [pscustomobject]@{value=@()}}
        if($Uri -match 'skiptoken') {
            if($global:scenario -eq 'late page failure'){throw 'Mock late page failure.'}
            return [pscustomobject]@{value=@($global:records|Select-Object -Skip 1)}
        }
        $next='https://graph.microsoft.com/v1.0/security/auditLog/queries/11111111-1111-1111-1111-111111111111/records?$skiptoken=next'
        if($global:scenario -eq 'repeated page'){$next=$Uri}
        if($global:scenario -eq 'foreign page'){$next='https://example.test/next'}
        return [pscustomobject]@{value=@($global:records[0]);'@odata.nextLink'=$next}
    }
    if($Uri -match '/security/auditLog/queries/') { return $global:query }
    throw "Unexpected request $Method $Uri"
}
$passed=0
foreach($scenario in @('preview','empty guests','auth failure','empty token','wrong identity','missing permission','user failure','query create failure','pending','query failed','wrong window','wrong operations','restricted query','empty records','late page failure','repeated page','foreign page','record limit','bad timestamp','unexpected operation','transient read','persistent gateway failure','transient create failure','forbidden read')) {
    $global:scenario=$scenario;$global:fixture=Get-Content (Join-Path $PSScriptRoot 'fixtures/guests.json') -Raw|ConvertFrom-Json
    $global:writes=0;$global:queries=0;$global:records=@();$global:recordReads=0
    foreach($r in $global:fixture.records){$r|Add-Member createdDateTime ([datetime]::UtcNow.AddDays(-$r.daysAgo).ToString('o'));$global:records+=,$r}
    # These deliberate fixture mutations simulate service and permission failures.
    if($scenario -eq 'wrong identity'){$global:fixture.claims.oid='wrong-identity'}
    if($scenario -eq 'missing permission'){$global:fixture.claims.roles=@('User.ReadWrite.All')}
    if($scenario -eq 'bad timestamp'){$global:records[0].createdDateTime='invalid'}
    if($scenario -eq 'unexpected operation'){$global:records[0].operation='Unexpected'}
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($global:fixture.claims|ConvertTo-Json -Compress)))
    $global:token='header.'+$payload+'.signature'
    $params=@{WaitSeconds=1};if($scenario -eq 'record limit'){$params.MaxRecords=1}
    $failed=$false;$output=@();$reason=''
    try{$output=@(& $runbook @params)}catch{$failed=$true;$reason=$_.ToString()}
    $expected=$scenario -notin @('preview','empty guests','transient read')
    if($failed -ne $expected){throw "Unexpected guest result $scenario : $reason"}
    if($global:writes){throw 'Directory write attempted.'}
    if($scenario -in @('preview','transient read')){
        if($output[-1] -notmatch '7 guests; 3 with activity; 2 recent accounts or invitation updates; 1 inactivity candidates; 1 other review items'){throw ('Wrong preview: '+$output[-1])}
        if(@($output|Where-Object {$_ -like 'REVIEW:*'}).Count -ne 2){throw 'Wrong review count.'}
    }
    if($scenario -eq 'empty guests' -and $global:queries -ne 0){throw 'Unneeded audit query.'}
    if($expected -and @($output|Where-Object {$_ -like 'REVIEW:*'}).Count){throw 'Candidates reported after incomplete query.'}
    if($scenario -eq 'transient read' -and $global:recordReads -ne 3){throw 'Read retry failed.'}
    if($scenario -eq 'persistent gateway failure' -and $global:recordReads -ne 4){throw 'Wrong retry limit.'}
    if($scenario -eq 'transient create failure' -and $global:queries -ne 1){throw 'Unsafe POST retry.'}
    if($scenario -eq 'forbidden read' -and $global:recordReads -ne 1){throw 'Unauthorized read retried.'}
    Write-Output "PASS: guest $scenario";$passed++
}
Write-Output "$passed guest preview scenarios passed."
