$ErrorActionPreference='Stop'
$runbook=Join-Path $PSScriptRoot '../Assign-UserLicenses.ps1'
$env:IDENTITY_ENDPOINT='http://test-identity'; $env:IDENTITY_HEADER='test-header'
$global:desktop='f245ecc8-75af-4f8e-b61f-27d8114de5f3';$global:basic='3b555118-da6a-4418-894f-7df1e2096870';$global:premium='cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46';$global:addon='00000000-0000-0000-0000-000000000099'
function Start-Sleep {param($Seconds) $global:sleeps++}
function Invoke-RestMethod {
 param($Method,$Uri,$Headers,$ContentType,$Body,$ErrorAction,$TimeoutSec)
 if ($Uri -eq 'http://test-identity') {
  if ($Body.resource -ne 'https://graph.microsoft.com') {throw 'Wrong Graph token resource'}
  if ($global:scenario -eq 'auth failure'){throw 'Mock auth failure'}
  return [pscustomobject]@{access_token='test-token'}
 }
 if ($Uri -match '/subscribedSkus$') {return [pscustomobject]@{value=@($global:fixture.skus)}}
 if ($Uri -match '/groups/([^/?]+)(.*)$') {
  $id=$Matches[1];$tail=$Matches[2];$g=@($global:fixture.groups|Where-Object id -eq $id)[0]
  if ($global:scenario -eq 'group failure'){throw 'Mock group failure'}
  if ($tail -match '/members') {
   $members=@($global:fixture.users|Where-Object {$id -in $_.groupIds}|ForEach-Object {[pscustomobject]@{id=$_.id;'@odata.type'='#microsoft.graph.user'}})
   return [pscustomobject]@{value=$members}
  }
  return $g
 }
 if ($Uri -match '/users\?') {
  if ($global:scenario -eq 'list failure'){throw 'Mock list failure'}
  if ($Uri -match 'skiptoken') {
   if ($global:scenario -eq 'page failure'){throw 'Mock page failure'}
   return [pscustomobject]@{value=@($global:fixture.users|Select-Object -Skip 2)}
  }
  return [pscustomobject]@{value=@($global:fixture.users|Select-Object -First 2);'@odata.nextLink'='https://graph.microsoft.com/v1.0/users?$skiptoken=second'}
 }
 if ($Uri -match '/users/([^/?]+)(.*)$') {
  $id=$Matches[1];$tail=$Matches[2];$u=@($global:fixture.users|Where-Object id -eq $id)[0]
  if ($tail -match '/memberOf') {
   $groups=@($u.groupIds)
   if ($global:scenario -eq 'membership changed'){$groups=@()}
   return [pscustomobject]@{value=@($groups|ForEach-Object {[pscustomobject]@{id=$_}})}
  }
  if ($Method -eq 'Patch') {
   $b=$Body|ConvertFrom-Json
   if (@($b.PSObject.Properties.Name).Count -ne 1 -or $b.usageLocation -ne 'CA'){throw 'Unexpected profile update'}
   $global:profileWrites++;$u.usageLocation=$b.usageLocation;return
  }
  if ($tail -eq '/assignLicense') {
   if ($global:scenario -eq 'write failure'){throw 'Mock license write failure'}
   $b=$Body|ConvertFrom-Json
   if (@($b.removeLicenses|Where-Object {$_ -notin @($global:desktop,$global:basic,$global:premium)}).Count){throw 'Unrelated license removal'}
   $global:writes++;$global:writtenIds+=@($u.id)
   $global:oldLicenses=@($u.assignedLicenses)
   $u.assignedLicenses=@($u.assignedLicenses|Where-Object {$_.skuId -notin $b.removeLicenses})+@($b.addLicenses)
   if ($global:scenario -eq 'license service error') { $u.licenseAssignmentStates=@($b.addLicenses | ForEach-Object { [pscustomobject]@{skuId=$_.skuId;assignedByGroup=$null;state='ActiveWithError'} }) }
   $global:lastWrite=$u.id;$global:verificationReads=0
   return $u
  }
  if ($global:lastWrite -eq $u.id) {
   $global:verificationReads++
   if ($global:scenario -eq 'verify failure' -or ($global:scenario -eq 'delayed verify' -and $global:verificationReads -le 2)) {
    $copy=$u|ConvertTo-Json -Depth 15|ConvertFrom-Json;$copy.assignedLicenses=$global:oldLicenses;return $copy
   }
  }
  return $u
 }
 throw "Unexpected API $Method $Uri"
}
$passed=0
foreach($scenario in @('preview','apply','auth failure','group failure','list failure','page failure','membership changed','write failure','verify failure','license service error','delayed verify','limit','capacity','inherited license','user scope','premium available','fallback desktop')) {
 $global:scenario=$scenario;$global:fixture=Get-Content (Join-Path $PSScriptRoot 'fixtures/licenses.json') -Raw|ConvertFrom-Json
 $global:writes=0;$global:profileWrites=0;$global:sleeps=0;$global:writtenIds=@();$global:lastWrite='';$global:verificationReads=0
 $mode=if($scenario -eq 'preview'){'Preview'}else{'Apply'};$params=@{Mode=$mode;MaxChanges=10}
 if($scenario -eq 'limit'){$params.MaxChanges=1}
 if($scenario -eq 'capacity'){$global:fixture.skus[1].prepaidUnits.enabled=0}
 if($scenario -eq 'inherited license'){$global:fixture.users[0].licenseAssignmentStates[0].assignedByGroup='unexpected-group'}
 if($scenario -eq 'user scope'){$params.UserIds=@($global:fixture.users[0].id)}
 if($scenario -in @('premium available','fallback desktop')) {
  $global:fixture.users[3].assignedLicenses=@([pscustomobject]@{skuId=$global:basic;disabledPlans=@()})
  $global:fixture.users[3].licenseAssignmentStates=@()
  if($scenario -eq 'premium available'){$global:fixture.skus[2].prepaidUnits.enabled=1}
  else{$global:fixture.skus[0].prepaidUnits.enabled=2}
 }
 $failed=$false;$reason=''
 try{$output=@(& $runbook @params 3>$null)}catch{$failed=$true;$reason=$_.ToString()}
 $expectedFailure=$scenario -in @('auth failure','group failure','list failure','page failure','membership changed','write failure','verify failure','license service error','limit','capacity','inherited license')
 if($failed -ne $expectedFailure){throw "Unexpected result for $scenario : $reason"}
 if($scenario -eq 'preview' -and ($global:writes -ne 0 -or $output[-1] -notmatch '2 license changes; 0 policy conflicts')){throw 'Wrong preview'}
 if($expectedFailure -and $scenario -notin @('verify failure','license service error') -and $global:writes -ne 0){throw "Write before validation for $scenario"}
 if($scenario -in @('apply','delayed verify')){
  if($global:writes -ne 2 -or $global:profileWrites -ne 1){throw 'Wrong normal write counts'}
  if($global:addon -notin @($global:fixture.users[0].assignedLicenses|ForEach-Object skuId)){throw 'Add-on lost'}
  if($global:desktop -notin @($global:fixture.users[2].assignedLicenses|ForEach-Object skuId)){throw 'Cloud-only license removed'}
  if($global:premium -notin @($global:fixture.users[3].assignedLicenses|ForEach-Object skuId)){throw 'Existing Premium downgraded'}
 }
 if($scenario -eq 'user scope' -and $global:writes -ne 1){throw 'User allowlist failed'}
 if($scenario -eq 'delayed verify' -and $global:sleeps -ne 4){throw 'Delayed read retries failed'}
 if($scenario -eq 'verify failure' -and $global:sleeps -ne 11){throw 'Verification retry limit failed'}
 if($scenario -eq 'premium available' -and $global:premium -notin @($global:fixture.users[3].assignedLicenses|ForEach-Object skuId)){throw 'Premium preference failed'}
 if($scenario -eq 'fallback desktop' -and $global:desktop -notin @($global:fixture.users[3].assignedLicenses|ForEach-Object skuId)){throw 'Desktop fallback failed'}
 Write-Output "PASS: $scenario";$passed++
}
Write-Output "$passed license scenarios passed."
