<#  
.SYNOPSIS 
    Script that enforces MFA of synced users
.NOTES 
#>

#Office 365 Admin Credentials
$Credential = Get-AutomationPSCredential -Name "Azure Automation Bot"

#Connect to Office 365 
Connect-MsolService -Credential $Credential

#Get all synced users without MFA enforced and put them in a custom object
$NonMFAUsers = Get-MsolUser -All | Where-Object {($_.ImmutableId -ne $null) -and ($_.StrongAuthenticationMethods.Count -eq 0)} | Select-Object -Property UserPrincipalName | Sort-Object UserPrincipalName


Get-MsolUser -All | Where-Object {($_.ImmutableId -ne $null) } | Select-Object DisplayName,
    @{N='E-mail';E={$_.UserPrincipalName}},
    @{N='MFA-Requirements';E={(($_).StrongAuthenticationRequirements.state)}},
    @{N='MFA-Methods';E={(($_).StrongAuthenticationMethods.MethodType)}}

Get-MsolUser -All | Select-Object DisplayName,
    @{
        N="MFA Status"; 
        E= { 
            if( $_.StrongAuthenticationRequirements.State -ne $null) {
                $_.StrongAuthenticationRequirements.State
            } else {
                "Disabled"
            }
        }
    }