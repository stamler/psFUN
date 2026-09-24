param(
    [ValidateSet('Preview', 'Apply')][string]$Mode = 'Preview',
    [ValidateRange(1, 500)][int]$MaxChanges = 10,
    [string[]]$UserIds = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Preserve the three existing group-to-plan mappings. Use IDs to avoid name ambiguity.
$mappings = @(
    @{ GroupId='754b52a3-0854-4564-81d7-737c2a16be2b'; GroupName='TBTE_Desktop_Software'; SkuId='f245ecc8-75af-4f8e-b61f-27d8114de5f3'; SkuName='O365_BUSINESS_PREMIUM'; Priority=2 },
    @{ GroupId='872d4475-cf3f-4498-be55-eb54ca37f99f'; GroupName='TBTE_Mobile_Software'; SkuId='3b555118-da6a-4418-894f-7df1e2096870'; SkuName='O365_BUSINESS_ESSENTIALS'; Priority=1 },
    @{ GroupId='f1487162-81bc-4051-8d0f-b123ab557060'; GroupName='TBTE_Premium_Software'; SkuId='cbdc14ab-d96c-4c30-b9f4-6ada7cdc1d46'; SkuName='SPB'; Priority=3 }
)
$managedSkuIds = @($mappings | ForEach-Object { $_.SkuId })
$userSelect = 'id,userPrincipalName,userType,accountEnabled,onPremisesImmutableId,usageLocation,assignedLicenses,licenseAssignmentStates'
if (!$env:IDENTITY_ENDPOINT -or !$env:IDENTITY_HEADER) { throw 'Automation managed identity endpoint is unavailable.' }
$identity = Invoke-RestMethod -Method Post -Uri $env:IDENTITY_ENDPOINT -Headers @{
    'X-IDENTITY-HEADER'=$env:IDENTITY_HEADER; Metadata='True'
} -ContentType 'application/x-www-form-urlencoded' -Body @{resource='https://graph.microsoft.com'} -ErrorAction Stop
if (!$identity.access_token) { throw 'Managed identity returned no access token.' }
$headers = @{Authorization='Bearer '+$identity.access_token}
function Invoke-LicenseGraph {
    param([string]$Uri, [string]$Method='Get', $Body=$null)
    if (!$Uri.StartsWith('https://graph.microsoft.com/v1.0/', [StringComparison]::Ordinal)) { throw 'Unexpected Graph URL.' }
    $request = @{Uri=$Uri; Method=$Method; Headers=$headers; ErrorAction='Stop'; TimeoutSec=60}
    if ($null -ne $Body) { $request.Body=ConvertTo-Json -InputObject $Body -Depth 10 -Compress; $request.ContentType='application/json' }
    Invoke-RestMethod @request
}
function Get-LicenseGraphPages {
    param([string]$Uri)
    $seen=@{}
    while ($Uri) {
        if ($seen.ContainsKey($Uri)) { throw 'Repeated Graph page.' }
        $seen[$Uri]=$true
        $page=Invoke-LicenseGraph $Uri
        foreach ($item in $page.value) { $item }
        $next=$page.PSObject.Properties['@odata.nextLink']
        $Uri=if ($next) { [string]$next.Value } else { $null }
    }
}
function Get-LicensePlan {
    param($User, [string[]]$Desired)
    $assigned=@($User.assignedLicenses | ForEach-Object { [string]$_.skuId })
    $add=@($Desired | Where-Object { $_ -notin $assigned })
    # The old removal scope was users with an on-premises immutable ID.
    # Remove only the three managed plans, never unrelated licenses.
    $remove=@()
    if (![string]::IsNullOrWhiteSpace($User.onPremisesImmutableId)) {
        $remove=@($assigned | Where-Object { $_ -in $managedSkuIds -and $_ -notin $Desired })
    }
    $problem=$null
    if (($add.Count -or $remove.Count) -and $User.userType -ne 'Member') { $problem='Non-member user requires manual review.' }
    if ($add.Count -or $remove.Count) {
        foreach ($state in $User.licenseAssignmentStates) {
            if ($state.skuId -in $managedSkuIds -and ($state.assignedByGroup -or $state.state -notin @('Active','Disabled'))) {
                $problem='Inherited or unresolved license assignment requires manual review.'
            }
        }
    }
    [pscustomobject]@{
        Id=[string]$User.id; User=[string]$User.userPrincipalName; Enabled=$User.accountEnabled
        Desired=@($Desired); Add=@($add); Remove=@($remove); Problem=$problem
        SetUsageLocation=($add.Count -gt 0 -and $User.usageLocation -ne 'CA')
    }
}
function Get-PlanKey {
    param($Plan)
    return (($Plan.Add | Sort-Object) -join ',')+'|'+(($Plan.Remove | Sort-Object) -join ',')+'|'+$Plan.SetUsageLocation+'|'+$Plan.Problem
}
$skus=@(Get-LicenseGraphPages 'https://graph.microsoft.com/v1.0/subscribedSkus')
$memberships=@{}
$available=@{}
foreach ($mapping in $mappings) {
    $sku=@($skus | Where-Object { $_.skuId -eq $mapping.SkuId -and $_.skuPartNumber -eq $mapping.SkuName })
    if ($sku.Count -ne 1 -or $sku[0].capabilityStatus -notin @('Enabled','Warning')) { throw "Missing or inactive SKU: $($mapping.SkuName)" }
    $available[$mapping.SkuId]=[int]$sku[0].prepaidUnits.enabled + [int]$sku[0].prepaidUnits.warning - [int]$sku[0].consumedUnits
    $group=Invoke-LicenseGraph ('https://graph.microsoft.com/v1.0/groups/'+$mapping.GroupId+'?$select=id,displayName')
    if ($group.displayName -ne $mapping.GroupName) { throw "License group name changed: $($mapping.GroupId)" }
    $members=@(Get-LicenseGraphPages ('https://graph.microsoft.com/v1.0/groups/'+$mapping.GroupId+'/members?$select=id&$top=999'))
    foreach ($member in $members) {
        if ($member.'@odata.type' -ne '#microsoft.graph.user') { throw "Non-user member in $($mapping.GroupName): $($member.id)" }
        if (!$memberships.ContainsKey($member.id)) { $memberships[$member.id]=@() }
        $memberships[$member.id]+=$mapping.SkuId
    }
    Write-Output "Group $($mapping.GroupName): $($members.Count) members; $($available[$mapping.SkuId]) seats currently free."
}
$users=@(Get-LicenseGraphPages ('https://graph.microsoft.com/v1.0/users?$select='+$userSelect+'&$top=999'))
$byId=@{}
$plans=@()
$problems=@()
$projected=@{}
foreach ($skuId in $available.Keys) { $projected[$skuId]=$available[$skuId] }
# Resolve single-group users first. Their planned releases can supply multi-group users.
$selectedUsers=@($users | Where-Object { !$UserIds.Count -or $_.id -in $UserIds } | Sort-Object userPrincipalName)
foreach ($user in $users) { $byId[$user.id]=$user }
foreach ($multiple in @($false,$true)) {
    foreach ($user in $selectedUsers) {
        $memberSkus=@()
        if ($memberships.ContainsKey($user.id)) { $memberSkus=@($memberships[$user.id]) }
        if (($memberSkus.Count -gt 1) -ne $multiple) { continue }
        $desired=@($memberSkus)
        if ($multiple) {
            $held=@($user.assignedLicenses | ForEach-Object { [string]$_.skuId })
            $choices=@($mappings | Where-Object {
                $_.SkuId -in $memberSkus -and ($_.SkuId -in $held -or $projected[$_.SkuId] -gt 0)
            } | Sort-Object -Property @{Expression={ [int]$_.Priority }; Descending=$true})
            if (!$choices.Count) { throw "No available plan in this user's license groups: $($user.userPrincipalName)" }
            $desired=@($choices[0].SkuId)
            Write-Warning "Multiple license groups: $($user.userPrincipalName). Selected $($choices[0].SkuName) using Premium > Desktop > Basic and available seats."
        }
        $plan=Get-LicensePlan $user $desired
        $plan | Add-Member -NotePropertyName GroupSkus -NotePropertyValue @($memberSkus)
        if ($plan.Problem) { $problems+=$plan; Write-Warning ('REVIEW: '+($plan | ConvertTo-Json -Depth 5 -Compress)) }
        if ($plan.Add.Count -or $plan.Remove.Count) {
            $plans+=$plan
            foreach ($skuId in $plan.Add) { $projected[$skuId]-- }
            foreach ($skuId in $plan.Remove) { $projected[$skuId]++ }
            Write-Output ('Candidate: '+($plan | ConvertTo-Json -Depth 5 -Compress))
        }
    }
}
foreach ($id in $memberships.Keys) { if (!$byId.ContainsKey($id)) { throw "Group member missing from complete user list: $id" } }
if ($Mode -eq 'Preview') {
    Write-Output "PREVIEW: $($users.Count) users checked; $($plans.Count) license changes; $($problems.Count) policy conflicts; no writes."
    return
}
if ($problems.Count) { throw 'Resolve license policy conflicts before Apply. No users changed.' }
if ($plans.Count -gt $MaxChanges) { throw "Found $($plans.Count) changes, above MaxChanges=$MaxChanges. No users changed." }
# Plan an order that has enough seats at every step, before changing any user.
$remaining=@($plans)
$ordered=@()
while ($remaining.Count) {
    $ready=@($remaining | Where-Object {
        $fits=$true
        foreach ($skuId in $_.Add) { if ($available[$skuId] -lt 1) { $fits=$false } }
        $fits
    } | Sort-Object @{Expression={$_.Add.Count}}, User)
    if (!$ready.Count) { throw 'Insufficient seats to apply the whole plan safely. No users changed.' }
    $chosen=$ready[0]; $ordered+=$chosen
    foreach ($skuId in $chosen.Add) { $available[$skuId]-- }
    foreach ($skuId in $chosen.Remove) { $available[$skuId]++ }
    $remaining=@($remaining | Where-Object { $_.Id -ne $chosen.Id })
}
$changed=0
foreach ($plan in $ordered) {
    $uri='https://graph.microsoft.com/v1.0/users/'+[guid]$plan.Id
    $current=Invoke-LicenseGraph ($uri+'?$select='+$userSelect)
    $currentGroups=@(Get-LicenseGraphPages ($uri+'/memberOf?$select=id&$top=999'))
    $desired=@($mappings | Where-Object { $_.GroupId -in @($currentGroups | ForEach-Object {$_.id}) } | ForEach-Object { $_.SkuId })
    if ((($desired | Sort-Object) -join ',') -ne (($plan.GroupSkus | Sort-Object) -join ',')) { throw "License group membership changed: $($plan.User)" }
    $fresh=Get-LicensePlan $current @($plan.Desired)
    if ((Get-PlanKey $fresh) -ne (Get-PlanKey $plan)) { throw "User or group state changed after preview: $($plan.User). Stop and run again." }
    $before=@($current.assignedLicenses | ForEach-Object { [string]$_.skuId })
    if ($fresh.SetUsageLocation) { Invoke-LicenseGraph $uri Patch @{usageLocation='CA'} | Out-Null }
    $adds=@($plan.Add | ForEach-Object { @{skuId=$_; disabledPlans=@()} })
    Invoke-LicenseGraph ($uri+'/assignLicense') Post @{addLicenses=$adds; removeLicenses=@($plan.Remove)} | Out-Null
    $expected=@(@($before | Where-Object { $_ -notin $plan.Remove }) + @($plan.Add) | Sort-Object -Unique)
    $confirmed=$false
    for ($attempt=0; $attempt -lt 12; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds 5 }
        $verified=Invoke-LicenseGraph ($uri+'?$select='+$userSelect)
        $licenseErrors=@($verified.licenseAssignmentStates | Where-Object { $_.skuId -in $plan.Add -and $_.state -in @('Error','ActiveWithError') })
        if ($licenseErrors.Count) { throw "License service reported an assignment error: $($plan.User)" }
        $actual=@($verified.assignedLicenses | ForEach-Object { [string]$_.skuId } | Sort-Object -Unique)
        if (($actual -join ',') -eq ($expected -join ',') -and (!$fresh.SetUsageLocation -or $verified.usageLocation -eq 'CA')) { $confirmed=$true; break }
    }
    if (!$confirmed) { throw "License change could not be verified: $($plan.User)" }
    $changed++
    Write-Output ('Changed and verified: '+($plan | ConvertTo-Json -Depth 5 -Compress))
}
Write-Output "COMPLETE: $changed users changed and verified; only the three managed plans were changed."
