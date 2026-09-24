# UserAutomation runbooks

These four files are the source copies of the managed-identity runbooks published to the Azure Automation account `UserAutomation` on September 24, 2026. The account is in resource group `Automation`. Each script uses the account's system-assigned managed identity and Microsoft Graph REST calls. They do not use the stored Azure Automation Bot credential.

The deployed runtime is Windows PowerShell 5.1. The scripts need no AzureAD, MSOnline, or Exchange Online module. Group IDs and the guest script's identity check are specific to TBTE.

## Behaviour and schedules

This table records the settings checked during the September 24 migration. Schedule settings are stored in Azure, not in these script files.

| Script | Behaviour | Schedule parameters |
| --- | --- | --- |
| `Disable-StaleRegistrations.ps1` | Disable enabled Windows Workplace registrations with a known last sign-in at least 90 days old. Report other stale platforms for review. | Hourly, minute 52: `Mode=Apply`, `MaxChanges=25` |
| `Assign-UserLicenses.ps1` | Use the three TBTE software groups to assign licenses. | Hourly, minute 55: `Mode=Apply`, `MaxChanges=10` |
| `Remove-LicensesFromDeletedUsers.ps1` | Read-only audit of deleted users and any saved license assignments. It does not restore users or change licenses. | Hourly; no parameters |
| `Remove-StaleGuests.ps1` | Read-only review of guest age, invitation updates, and three audit operations over 90 days. It cannot delete guests. | Hourly, minute 52; no parameters |

The Azure schedule named `Daily` runs hourly. Check its recurrence rather than relying on its name.

Both scripts with an Apply mode default to Preview. Their change limits stop a run before writes if the plan exceeds the limit. Apply runs recheck each target and verify each write. A later failure can leave earlier changes applied; these jobs are not transactions.

### License policy

- `TBTE_Desktop_Software` selects Business Standard (`O365_BUSINESS_PREMIUM`).
- `TBTE_Mobile_Software` selects Business Basic (`O365_BUSINESS_ESSENTIALS`).
- `TBTE_Premium_Software` selects Business Premium (`SPB`).
- Group membership is authoritative, including for disabled accounts.
- Multiple groups produce a warning. Select the highest available plan: Premium > Desktop > Basic. An already-held plan counts as available.
- Preserve unrelated licenses. Remove managed plans only from users with an on-premises immutable ID, as in the old script.
- Before adding a license, set usage location to `CA` if it differs.

### Guest preview limits

The preview searches `UserLoggedIn`, `SecureLinkUsed`, and `TeamsSessionStarted`. It stops if the query fails, is incomplete, has unexpected filters, or returns no tenant activity. It reads every result page before reporting review candidates.

These three operations do not cover every successful sign-in. During validation, a separate Entra sign-in check excluded one audit-only candidate. The published script does not yet include that extra check. Add the last-successful-sign-in safeguard and complete a business review before implementing automatic deletion. No guest deletion is enabled in this version.

### Deleted-user audit

The old script restored deleted users, removed their licenses, then deleted them again. The replacement only reports saved assignments. A saved assignment does not establish that a license seat is still consumed.

## Identity and permissions

The system-assigned identity object ID is `6959416e-404d-4485-a5af-e23264eb240d`. These permissions were assigned at migration time; this is a record of the account's grants, not a minimum-permission template for other tenants.

| Grant | Purpose |
| --- | --- |
| Graph `Device.ReadWrite.All` and Entra `Cloud Device Administrator` | Disable stale registrations |
| Graph `User.ReadWrite.All` | License changes and usage-location updates; user reads |
| Graph `GroupMember.ReadBasic.All` | Read license group membership |
| Graph `LicenseAssignment.Read.All` | Read licensing data |
| Graph `AuditLogsQuery.Read.All` | Create and read Microsoft 365 audit queries |
| Graph `User.Read.All` | Existing read grant, retained after the read/write grant was added |

The old bot account, its roles, stored credential, and risk state were not changed by this migration.

## Tests

From the repository root, run the following in PowerShell 7 with `pwsh` on PATH. Each test file runs in its own process, so its mocks cannot affect another file or your session.

```powershell
$ErrorActionPreference = 'Stop'
Get-ChildItem ./tests/*.Tests.ps1 | Sort-Object Name | ForEach-Object {
    & pwsh -NoLogo -NoProfile -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Test failed: $($_.Name)" }
}
```

The tests mock all service calls and use synthetic user data. They make no Azure changes. The 59 cases cover normal results, preview and Apply behaviour, limits, pagination, permission failures, write failures, delayed verification, and guest query failures. Device test objects are created in the test file; the other suites use JSON fixtures. Fixture changes within tests simulate the named case.

All 59 cases passed with PowerShell 7.6.6 when these files were added. Earlier live validation used the Azure PowerShell 5.1 runtime. The unrelated `radiator/ConvertTo-Json` submodule has its own Pester 4 tests.

## Deployment and verification

A Git commit does not publish a runbook or change its schedule. There is no deployment automation added here. To update Azure, back up its published content and schedule binding, upload the revised file as a draft, test it, publish it, and verify the published content and job result. Check the schedule binding after publication because Azure can replace its binding ID.

The source files at migration commit `3d01317` match the SHA-256 hashes recorded after deployment. Later comment changes alter file hashes without changing runbook behaviour:

| Script | SHA-256 |
| --- | --- |
| `Disable-StaleRegistrations.ps1` | `0c9d2fce619bd88746a837374408eca80f9a181dbf5c57e46cb7b362531ee56c` |
| `Assign-UserLicenses.ps1` | `302ee676ef51c8cca6f3f0ac36767fd45a6845a4563798615d3510aebb9597a9` |
| `Remove-LicensesFromDeletedUsers.ps1` | `7f5be2e517f2743442f6c8e15766c0ab6ff7052ba21635f3fd13307d6fd0109c` |
| `Remove-StaleGuests.ps1` | `e41e25b7815ad618c8695e4c3f82eeaa86999d2b8640a4ed1c2aec190d09ba0b` |

At migration time, scheduled device runs and published jobs for the other three scripts completed successfully. The licensing Apply check needed no changes, so it did not exercise a real license or usage-location write. Local tests cover those write paths. Guest and deleted-user checks made no directory changes.

Private tenant exports, review lists, tokens, and job logs are not part of this repository change.
