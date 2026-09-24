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
    if ($Method -eq 'Delete') {
        $global:deleteAttempts++
        if ($Uri -notmatch '^https://graph.microsoft.com/v1\.0/users/([0-9a-f-]{36})$') { throw 'Wrong delete endpoint.' }
        $id=$Matches[1]
        if ($id -notin @('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000011')) { throw 'Protected guest deletion attempted.' }
        if ($global:scenario -eq 'delete failure') { throw [GuestMockHttpException]::new(403) }
        if ($global:scenario -eq 'transient delete failure') { throw [GuestMockHttpException]::new(504) }
        $global:writes++;$global:deletedIds+=@($id);$global:verifyReads=0
        return
    }
    if ($Uri -match '/directory/deletedItems/([0-9a-f-]{36})') {
        $id=$Matches[1];$global:verifyReads++
        if ($id -notin $global:deletedIds) { throw 'Verified an undeleted guest.' }
        if ($global:scenario -eq 'verify failure' -or ($global:scenario -eq 'delayed verify' -and $global:verifyReads -lt 3)) { throw [GuestMockHttpException]::new(404) }
        if ($global:scenario -eq 'verify forbidden') { throw [GuestMockHttpException]::new(403) }
        return [pscustomobject]@{id=$id}
    }
    if ($Method -ne 'Get' -and !($Method -eq 'Post' -and $Uri -eq 'https://graph.microsoft.com/v1.0/security/auditLog/queries')) { throw 'Unexpected directory write.' }
    if ($Uri -match "/users\?.*filter=id eq '([^']+)'") {
        $id=$Matches[1]
        if ($global:scenario -eq 'recheck failure') { throw [GuestMockHttpException]::new(403) }
        if ($global:scenario -eq 'recheck absent') { return [pscustomobject]@{value=@()} }
        $guest=@($global:fixture.guests | Where-Object id -eq $id)[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        # Deliberate mutations model changes between planning and the write.
        if ($global:scenario -eq 'recheck recent success') { $guest.signInActivity.lastSuccessfulSignInDateTime=[datetime]::UtcNow.ToString('o') }
        if ($global:scenario -eq 'recheck unknown success') { $guest.signInActivity.lastSuccessfulSignInDateTime=$null }
        if ($global:scenario -eq 'recheck member') { $guest.userType='Member' }
        if ($global:scenario -eq 'recheck alias changed') { $guest.otherMails=@('changed@example.test') }
        if ($global:scenario -eq 'recheck invitation changed') { $guest.externalUserStateChangeDateTime=[datetime]::UtcNow.ToString('o') }
        if ($global:scenario -eq 'recheck duplicate') { return [pscustomobject]@{value=@($guest,$guest)} }
        if ($global:scenario -eq 'recheck wrong id') { $guest.id='00000000-0000-0000-0000-000000000099' }
        return [pscustomobject]@{value=@($guest)}
    }
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
        if($global:scenario -eq 'success at cutoff'){$global:fixture.guests[7].signInActivity.lastSuccessfulSignInDateTime=$global:query.filterStartDateTime}
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
$applyCases=@('apply','batch limit','delayed verify','delete failure','transient delete failure','verify failure','verify forbidden','recheck failure','recheck recent success','recheck unknown success','recheck member','recheck alias changed','recheck invitation changed','recheck absent','recheck duplicate','recheck wrong id','apply reused query','missing delete permission')
$extraCases=@('success at cutoff','missing signin permission','null success','invalid success','missing activity','null activity','invalid attempt','invalid creation','invalid invitation','non-guest list','duplicate guest')
$passed=0
foreach($scenario in @('preview','empty guests','auth failure','empty token','wrong identity','missing permission','user failure','query create failure','pending','query failed','wrong window','wrong operations','restricted query','empty records','late page failure','repeated page','foreign page','record limit','bad timestamp','unexpected operation','transient read','persistent gateway failure','transient create failure','forbidden read')+$applyCases+$extraCases) {
    $global:scenario=$scenario;$global:fixture=Get-Content (Join-Path $PSScriptRoot 'fixtures/guests.json') -Raw|ConvertFrom-Json
    $global:writes=0;$global:queries=0;$global:records=@();$global:recordReads=0;$global:deletedIds=@();$global:deleteAttempts=0;$global:verifyReads=0
    foreach($r in $global:fixture.records){$r|Add-Member createdDateTime ([datetime]::UtcNow.AddDays(-$r.daysAgo).ToString('o'));$global:records+=,$r}
    # These deliberate fixture mutations simulate service and permission failures.
    if($scenario -eq 'wrong identity'){$global:fixture.claims.oid='wrong-identity'}
    if($scenario -eq 'missing permission'){$global:fixture.claims.roles=@('User.ReadWrite.All')}
    if($scenario -eq 'bad timestamp'){$global:records[0].createdDateTime='invalid'}
    if($scenario -eq 'unexpected operation'){$global:records[0].operation='Unexpected'}
    if($scenario -eq 'missing signin permission'){$global:fixture.claims.roles=@('User.ReadWrite.All','AuditLogsQuery.Read.All')}
    if($scenario -eq 'missing delete permission'){$global:fixture.claims.roles=@('User.Read.All','AuditLogsQuery.Read.All','AuditLog.Read.All')}
    if($scenario -eq 'null success'){$global:fixture.guests[1].signInActivity.lastSuccessfulSignInDateTime=$null}
    if($scenario -eq 'invalid success'){$global:fixture.guests[1].signInActivity.lastSuccessfulSignInDateTime='invalid'}
    if($scenario -eq 'missing activity'){$global:fixture.guests[1].PSObject.Properties.Remove('signInActivity')}
    if($scenario -eq 'null activity'){$global:fixture.guests[1].signInActivity=$null}
    if($scenario -eq 'invalid attempt'){$global:fixture.guests[1].signInActivity.lastSignInDateTime='invalid'}
    if($scenario -eq 'invalid creation'){$global:fixture.guests[1].createdDateTime='invalid'}
    if($scenario -eq 'invalid invitation'){$global:fixture.guests[1].externalUserStateChangeDateTime='invalid'}
    if($scenario -eq 'non-guest list'){$global:fixture.guests[1].userType='Member'}
    if($scenario -eq 'duplicate guest'){$global:fixture.guests+=@($global:fixture.guests[1])}
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($global:fixture.claims|ConvertTo-Json -Compress)))
    $global:token='header.'+$payload+'.signature'
    $params=@{WaitSeconds=1};if($scenario -eq 'record limit'){$params.MaxRecords=1}
    if($scenario -in $applyCases){$params.Mode='Apply'}
    if($scenario -eq 'batch limit'){$params.MaxDeletions=1}
    if($scenario -eq 'apply reused query'){$params.AuditQueryId='11111111-1111-1111-1111-111111111111'}
    $failed=$false;$output=@();$reason=''
    try{$output=@(& $runbook @params)}catch{$failed=$true;$reason=$_.ToString()}
    $successCases=@('preview','empty guests','transient read','apply','batch limit','delayed verify','recheck recent success','recheck unknown success','recheck member','recheck alias changed','recheck invitation changed','recheck absent','success at cutoff','null success','invalid success','missing activity','null activity','invalid attempt','invalid creation','invalid invitation')
    $expected=$scenario -notin $successCases
    if($failed -ne $expected){throw "Unexpected guest result $scenario : $reason"}
    $expectedWrites=0
    if($scenario -in @('apply','delayed verify')){$expectedWrites=2}
    if($scenario -in @('batch limit','verify failure','verify forbidden')){$expectedWrites=1}
    if($global:writes -ne $expectedWrites){throw "Wrong deletion count for $scenario : $($global:writes)"}
    if($scenario -in @('preview','transient read','success at cutoff','apply')){
        if(@($output|Where-Object {$_ -match '^PLAN: 11 guests; 5 with activity; 2 recent accounts or invitation updates; 2 deletion candidates; 2 review items'}).Count -ne 1){throw ('Wrong preview: '+($output -join '\n'))}
        if(@($output|Where-Object {$_ -like 'REVIEW:*'}).Count -ne 2){throw 'Wrong review count.'}
        $candidateText=($output|Where-Object {$_ -like 'CANDIDATE:*'}) -join '\n'
        if($candidateText -match 'successful-recent|unknown-signin|noninteractive-recent'){throw 'Protected guest in candidates.'}
    }
    if($scenario -in @('null success','invalid success','missing activity','null activity','invalid attempt','invalid creation','invalid invitation')) {
        if(@($output|Where-Object {$_ -like 'CANDIDATE:*'}).Count -ne 1){throw 'Unknown data was treated as inactivity.'}
    }
    if($scenario -eq 'batch limit' -and $output[-1] -notmatch '1 deferred by MaxDeletions=1'){throw 'Batch limit failed.'}
    if($scenario -eq 'empty guests' -and $global:queries -ne 0){throw 'Unneeded audit query.'}
    if($expected -and $scenario -notin $applyCases -and @($output|Where-Object {$_ -match '^(REVIEW|CANDIDATE):'}).Count){throw 'Candidates reported after incomplete query.'}
    if($scenario -eq 'transient read' -and $global:recordReads -ne 3){throw 'Read retry failed.'}
    if($scenario -eq 'persistent gateway failure' -and $global:recordReads -ne 4){throw 'Wrong retry limit.'}
    if($scenario -eq 'transient create failure' -and $global:queries -ne 1){throw 'Unsafe POST retry.'}
    if($scenario -eq 'forbidden read' -and $global:recordReads -ne 1){throw 'Unauthorized read retried.'}
    if($scenario -eq 'transient delete failure' -and $global:deleteAttempts -ne 1){throw 'Unsafe DELETE retry.'}
    if($scenario -eq 'verify failure' -and $global:verifyReads -ne 6){throw 'Wrong verification retry limit.'}
    if($scenario -eq 'verify forbidden' -and $global:verifyReads -ne 1){throw 'Permission failure retried.'}
    if($scenario -like 'recheck *' -and $global:deleteAttempts){throw 'Deletion attempted after unsafe recheck.'}
    Write-Output "PASS: guest $scenario";$passed++
}
Write-Output "$passed guest cleanup scenarios passed."
