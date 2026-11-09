<#
.SYNOPSIS
Rename one on-premises AD user everywhere, keeping the old address as an alias.

.DESCRIPTION
Performs a full rename of one person's account in on-premises Active Directory
at TBTE. After this script runs and Entra Connect syncs, the person has a new
Windows login, a new Microsoft 365 sign-in, a new primary email address and a
new display name. The only remaining use of the old name is one email alias, so
mail sent to the old address still arrives.

The script only changes Active Directory. It never contacts Microsoft Entra ID,
Exchange Online or the person's computer. Entra Connect carries the change to
the cloud on its next sync.

WHY THE CHANGE IS MADE IN AD
Accounts in OU=Human Users are synced from AD, so AD is the source of authority.
Exchange Online and Entra ID will not accept edits to these addresses. The sync
keeps the same cloud account because it matches on the immutable ID (source
anchor), not on any name. The mailbox, licences, group memberships and Teams
membership all stay with the account. No new account is created.

WHAT THE SCRIPT ASKS FOR
  OldUsername     The current login, such as jdoe.
  NewUsername     The new login, such as jroe.
  NewDisplayName  The new full name, such as Jane Roe.

PowerShell prompts for any of these that are not given on the command line.
The username is also the email prefix. The email domain comes from the account's
current UPN, so jdoe@tbte.ca becomes jroe@tbte.ca.

The surname is the last word of NewDisplayName unless -Surname is given. Use
-Surname for a surname containing a space, such as 'van der Berg'. The given
name is never changed.

WHAT THE SCRIPT CHANGES
With OldUsername jdoe, NewUsername jroe and NewDisplayName Jane Roe, one
Set-ADUser call makes these changes together:

  sAMAccountName      jdoe          -> jroe
  userPrincipalName   jdoe@tbte.ca  -> jroe@tbte.ca
  mail                jdoe@tbte.ca  -> jroe@tbte.ca
  sn                  Doe           -> Roe
  displayName         Jane Doe      -> Jane Roe
  mailNickname        jdoe          -> jroe
  proxyAddresses      see below

mailNickname is changed only if the account already has a value. Not every
account has this attribute, and the attribute does not exist at all in an AD
schema that Exchange never extended.

A second call, Rename-ADObject, then changes the object's CN to the new display
name. This also changes the account's distinguished name. The account stays in
the same OU.

HOW proxyAddresses IS BUILT
proxyAddresses decides which addresses the mailbox has. The entry with uppercase
SMTP: is the primary address. Entries with lowercase smtp: are aliases.

The script keeps every existing entry except any entry for the old or new
address on this domain. It then adds these two entries:

  SMTP:<new username>@<domain>     the new primary address
  smtp:<old username>@<domain>     the old address, now an alias

Other entries, such as X500 addresses, SIP addresses or aliases on lbegroup.ca
and washteh.ca, are not touched. Earlier aliases also stay, so a second rename
of the same person keeps the first old address. Renaming someone back to an
address they already hold as an alias works: that alias becomes the primary.

The UPN, mail and proxyAddresses change in the same call because Microsoft warns
that changing the UPN alone can leave the primary SMTP address out of step.

CHECKS MADE BEFORE ANY CHANGE
Any failed check stops the script before anything is written.

  1. OldUsername and NewUsername are different. Each is 1 to 20 characters of
     letters, digits, dot, underscore or hyphen. 20 is the sAMAccountName limit.
  2. The old account exists and its UPN is <OldUsername>@<domain>. This rejects
     accounts whose login and sign-in differ, such as a login of jdoe with a UPN
     of jane@tbte.ca.
  3. No Exchange server is registered in the AD configuration partition. If one
     exists, email address policies could overwrite these values, and the
     address changes belong in the Exchange tools instead.
  4. The account's mail attribute is empty or equals the old address.
  5. proxyAddresses has no uppercase SMTP: entry other than the old address.
     This rejects accounts whose email prefix differs from their login, such as
     jane.doe@tbte.ca with a login of jdoe.
  6. No other AD object has the new login, UPN, mail or proxy address. Users,
     groups and contacts are all searched. This excludes the account itself.
  7. No other object in the same OU has the new CN. Without this check the
     Rename-ADObject call could fail after the attributes have already changed.

LIMIT OF CHECK 6: it searches AD only and cannot see cloud-only objects. Before
renaming, confirm in Entra ID that no cloud-only group, shared mailbox or contact
already uses the new address. If one does, Entra Connect quarantines the
conflicting value and reports a provisioning error on the account.

ORDER OF OPERATIONS
  1. Validate the input and read the account with all of its attributes.
  2. Make the checks listed above. Nothing has been written at this point.
  3. Show every planned change and wait for the operator to type YES. The answer
     is case sensitive. Any other answer exits without changing anything, which
     makes this screen a safe preview.
  4. Save the complete account to rename-<old username>-<timestamp>.xml in the
     operator's home folder. The file holds the account's AD attributes, but no
     password. Read it with Import-Clixml.
  5. Change the attributes with Set-ADUser.
  6. Change the CN with Rename-ADObject, if the CN differs from the display name.
  7. Warn about homeDirectory, profilePath, scriptPath or targetAddress values
     that still contain the old username. The script does not change these,
     because the first three point at real folders and files that must be
     renamed with them.
  8. Read the account back and print the result.

FAILURE AND ROLLBACK
The script stops at the first error. There is no automatic rollback.

If Set-ADUser fails, compare the account with the backup file before trying
again. If Rename-ADObject fails, the attributes are already changed and only the
CN is old. The script says so and gives the command that finishes the job.

To reverse a completed rename, run the script again with the names swapped and
the old display name. Add -Surname if the old surname was not the last word. This
leaves the newer name behind as an alias, so remove that entry from
proxyAddresses if it is unwanted. A reversal moves the OneDrive URL again.

WHAT THE SCRIPT DOES NOT DO
  - It does not start a sync. Allow AD to replicate, then run
    AzureAD_delta_sync.ps1 on the Entra Connect server, or wait for the next
    scheduled sync.
  - It does not rename C:\Users\<old username> on the person's computer. Windows
    keeps the folder name. Removing it requires a new profile and a data move.
  - It does not change the given name.
  - It does not change other systems that store the old address or login, such
    as SaaS accounts, Cloudflare ZTNA or vendor licensing portals.

WHAT THE PERSON WILL NOTICE
  - The person must sign out of their computer before the rename.
  - The next Windows login uses MAIN\<new username> on the office network or VPN,
    because the computer has no cached login for the new name.
  - Microsoft 365 sign-in uses the new address with the same password.
  - The OneDrive URL changes with the UPN. Microsoft says that this can take
    several hours to propagate. Shared links, bookmarks and recent-file lists
    stop working, and files must be re-shared.
  - The OneDrive sync client switches by itself but can show an error until it is
    restarted. OneNote notebooks in OneDrive must be closed and reopened.
  - Teams Meeting Notes created under the old UPN must be downloaded from
    OneDrive, under Microsoft Teams Data > Wiki.
  - Microsoft Authenticator can stop receiving prompts. Remove the account and add
    it again if that happens. Registered phones may need to re-register.
  - Do the rename off-peak, with support available the next morning.

CONFIRMING THE RESULT
After the sync, check the account in Entra ID: UPN, mail, proxyAddresses and an
empty onPremisesProvisioningErrors list. In Exchange Online, check the mailbox
PrimarySmtpAddress and EmailAddresses. Then send an external test message to the
new address and to the old address.

.PARAMETER OldUsername
The current sAMAccountName. Must also be the current UPN prefix and email prefix.

.PARAMETER NewUsername
The new sAMAccountName, UPN prefix and email prefix.

.PARAMETER NewDisplayName
The new display name and CN. Allows letters, combining marks, spaces, apostrophes,
periods and hyphens.

.PARAMETER Surname
The new surname. Default: the last word of NewDisplayName.

.EXAMPLE
.\Rename-User.ps1
Prompt for the old username, new username and new display name.

.EXAMPLE
.\Rename-User.ps1 -OldUsername jdoe -NewUsername jroe -NewDisplayName 'Jane Roe'
Rename Jane Doe to Jane Roe after showing the plan.

.EXAMPLE
.\Rename-User.ps1 -OldUsername jsmith -NewUsername jvanderberg -NewDisplayName 'Jan van der Berg' -Surname 'van der Berg'
Rename a user whose new surname contains spaces.

.NOTES
Run as a domain admin on a computer with the ActiveDirectory module. Works in
Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode is deliberately off. Get-ADUser -Properties * omits attributes
that have no value, and reading those as empty is expected here.
#>

#Requires -Modules ActiveDirectory

param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._-]{1,20}$')][string]$OldUsername,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._-]{1,20}$')][string]$NewUsername,
    [Parameter(Mandatory)][ValidatePattern("^[\p{L}\p{M}' .-]+$")][string]$NewDisplayName,
    [string]$Surname
)
$ErrorActionPreference = 'Stop'

$NewDisplayName = $NewDisplayName.Trim()
if (-not $Surname) { $Surname = ($NewDisplayName -split '\s+')[-1] }
if ($OldUsername -eq $NewUsername) { throw 'The old and new usernames are the same.' }

$user = Get-ADUser -Identity $OldUsername -Properties *
if (-not $user.UserPrincipalName -or $user.UserPrincipalName -notmatch '@') {
    throw "$OldUsername has no valid UPN."
}
$domain = $user.UserPrincipalName.Split('@')[1]
$oldAddress = "$OldUsername@$domain"
$newAddress = "$NewUsername@$domain"

# Every check runs before the first write.
if ($user.UserPrincipalName -ne $oldAddress) {
    throw "The UPN is $($user.UserPrincipalName), not $oldAddress."
}
$configuration = (Get-ADRootDSE).configurationNamingContext
if (Get-ADObject -SearchBase $configuration -LDAPFilter '(objectClass=msExchExchangeServer)') {
    throw 'An Exchange server is registered in AD. Use the Exchange tools for the address changes.'
}
if ($user.mail -and $user.mail -ne $oldAddress) {
    throw "The mail attribute is $($user.mail), not $oldAddress."
}
$otherPrimary = @($user.proxyAddresses | Where-Object { $_ -cmatch '^SMTP:' -and $_ -ne "SMTP:$oldAddress" })
if ($otherPrimary.Count -gt 0) { throw "The primary address is not $oldAddress : $($otherPrimary -join ', ')" }

$conflictFilter = "(|(sAMAccountName=$NewUsername)(userPrincipalName=$newAddress)(mail=$newAddress)(proxyAddresses=smtp:$newAddress))"
$conflicts = @(Get-ADObject -LDAPFilter $conflictFilter | Where-Object { $_.ObjectGUID -ne $user.ObjectGUID })
if ($conflicts.Count -gt 0) { throw "The new name is in use by: $($conflicts.DistinguishedName -join '; ')" }

# The lookbehind keeps an escaped comma inside the CN from ending the match.
$parent = $user.DistinguishedName -replace '^CN=.+?(?<!\\),', ''
$cnConflicts = @(Get-ADObject -SearchBase $parent -SearchScope OneLevel -LDAPFilter "(cn=$NewDisplayName)" |
    Where-Object { $_.ObjectGUID -ne $user.ObjectGUID })
if ($cnConflicts.Count -gt 0) { throw "$parent already contains CN=$NewDisplayName." }

# Keep unrelated addresses. A null entry would make AD reject the whole write.
$replaced = "smtp:$oldAddress", "smtp:$newAddress"
$addresses = @($user.proxyAddresses | Where-Object { $_ -and $replaced -notcontains $_ }) +
    "SMTP:$newAddress", "smtp:$oldAddress"

$backup = Join-Path $HOME "rename-$OldUsername-$(Get-Date -Format yyyyMMdd-HHmmss).xml"
Write-Host ''
Write-Host "Login:          $($user.SamAccountName) -> $NewUsername"
Write-Host "UPN:            $($user.UserPrincipalName) -> $newAddress"
Write-Host "Mail:           $($user.mail) -> $newAddress"
Write-Host "Display name:   $($user.DisplayName) -> $NewDisplayName"
Write-Host "Surname:        $($user.Surname) -> $Surname"
Write-Host "CN:             $($user.Name) -> $NewDisplayName"
if ($user.mailNickname) { Write-Host "Mail nickname:  $($user.mailNickname) -> $NewUsername" }
Write-Host "Addresses:      $($addresses -join ', ')"
Write-Host "Backup:         $backup"
Write-Host ''
if ((Read-Host 'Type YES to apply') -cne 'YES') {
    Write-Host 'Cancelled. Nothing changed.'
    return
}

$user | Export-Clixml -Path $backup

$replace = @{ proxyAddresses = [string[]]$addresses; mail = $newAddress }
if ($user.mailNickname) { $replace.mailNickname = $NewUsername }
Set-ADUser -Identity $user.ObjectGUID -SamAccountName $NewUsername -UserPrincipalName $newAddress `
    -Surname $Surname -DisplayName $NewDisplayName -Replace $replace

if ($user.Name -cne $NewDisplayName) {
    try {
        Rename-ADObject -Identity $user.ObjectGUID -NewName $NewDisplayName
    } catch {
        throw "The attributes changed, but the CN did not: $_ To finish, run: Rename-ADObject -Identity $($user.ObjectGUID) -NewName '$($NewDisplayName -replace "'", "''")'"
    }
}

foreach ($attribute in 'homeDirectory', 'profilePath', 'scriptPath', 'targetAddress') {
    if ($user.$attribute -match [regex]::Escape($OldUsername)) {
        Write-Warning "$attribute still uses the old name: $($user.$attribute)"
    }
}

Get-ADUser -Identity $user.ObjectGUID -Properties mail, proxyAddresses, DisplayName |
    Format-List SamAccountName, UserPrincipalName, DistinguishedName, DisplayName, Surname, mail,
    @{ Name = 'proxyAddresses'; Expression = { $_.proxyAddresses -join ', ' } }
Write-Host 'Done. Run AzureAD_delta_sync.ps1 on the Entra Connect server after AD replicates.'
