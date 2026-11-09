# UserAutomation runbooks

These four files are the source copies of the managed-identity runbooks migrated to the Azure Automation account `UserAutomation` on September 24, 2026. The guest-cleanup deletion update was published and enabled on September 25. The account is in resource group `Automation`. Each script uses the account's system-assigned managed identity and Microsoft Graph REST calls. They do not use the stored Azure Automation Bot credential.

The deployed runtime is Windows PowerShell 5.1. The scripts need no AzureAD, MSOnline, or Exchange Online module. Group IDs and the guest script's identity check are specific to TBTE.

## Behaviour and schedules

This table records the settings checked during the September 24 migration and the September 25 guest-cleanup deployment. Schedule settings are stored in Azure, not in these script files.

| Script | Behaviour | Schedule parameters |
| --- | --- | --- |
| `Disable-StaleRegistrations.ps1` | Disable enabled Windows Workplace registrations with a known last sign-in at least 90 days old. Report other stale platforms for review. | Hourly, minute 52: `Mode=Apply`, `MaxChanges=25` |
| `Assign-UserLicenses.ps1` | Use the three TBTE software groups to assign licenses. | Hourly, minute 55: `Mode=Apply`, `MaxChanges=10` |
| `Remove-LicensesFromDeletedUsers.ps1` | Read-only audit of deleted users and any saved license assignments. It does not restore users or change licenses. | Hourly; no parameters |
| `Remove-StaleGuests.ps1` | Delete eligible inactive guests after sign-in and audit checks. Keep unknown history for review. | Hourly, minute 52: `Mode=Apply`, `MaxDeletions=10` |

The Azure schedule named `Daily` runs hourly. Check its recurrence rather than relying on its name.

All scripts with an Apply mode default to Preview. Device cleanup and license assignment stop before writes if the plan exceeds their change limit. Guest cleanup processes at most MaxDeletions candidates and defers the rest. Apply runs recheck each target and verify each write. A later failure can leave earlier changes applied; these jobs are not transactions.

### License policy

- `TBTE_Desktop_Software` selects Business Standard (`O365_BUSINESS_PREMIUM`).
- `TBTE_Mobile_Software` selects Business Basic (`O365_BUSINESS_ESSENTIALS`).
- `TBTE_Premium_Software` selects Business Premium (`SPB`).
- Group membership is authoritative, including for disabled accounts.
- Multiple groups produce a warning. Select the highest available plan: Premium > Desktop > Basic. An already-held plan counts as available.
- Preserve unrelated licenses. Remove managed plans only from users with an on-premises immutable ID, as in the old script.
- Before adding a license, set usage location to `CA` if it differs.

### Guest cleanup update

The deployed script performs automatic deletion with these checks:

- Keep guests with a successful interactive or non-interactive sign-in within 90 days. Recent sign-in attempts also protect an account.
- Keep guests with recent account creation, invitation changes, or matching `UserLoggedIn`, `SecureLinkUsed`, or `TeamsSessionStarted` audit activity.
- Leave missing or invalid successful-sign-in history for manual review. This includes invitations that were never accepted.
- Require complete directory and audit reads before selecting candidates. Permission failures and incomplete audit results stop the run.
- Default to Preview. Apply must create a fresh audit query, read each guest again, check for changes, and verify each deletion in Deleted users.
- Delete at most ten guests per run by default, oldest first. Defer the rest to later runs. A failed write stops the job; prior writes are not rolled back.

Microsoft can delay sign-in and audit reports. Rechecking the records reduces the risk but does not remove that reporting delay. Deletion uses the recoverable user-delete endpoint; this script never permanently purges an account.

Graph `AuditLog.Read.All` was approved and granted on September 24 for Entra sign-in data. It is separate from `AuditLogsQuery.Read.All` for Microsoft 365 activity queries. On September 25, the existing managed identity received the new permission in its token. The live Preview passed with a complete 90-day audit search and an independent directory/sign-in check. The published Apply check then deleted ten eligible guests and verified each in Deleted users. The existing hourly binding now uses Apply with a ten-deletion limit. The 88 offline tests passed before deployment.

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
| Graph `AuditLog.Read.All` | Read Entra sign-in data; granted September 24 and verified in the managed-identity run on September 25 |
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

The tests mock all service calls and use synthetic user data. They make no Azure changes. The 88 cases cover normal results, preview and Apply behaviour, limits, pagination, permission failures, write failures, delayed verification, and guest query failures. Device test objects are created in the test file; the other suites use JSON fixtures. Fixture changes within tests simulate the named case.

The original 59 cases passed when these files were added. The guest cleanup update expands the runbook suite to 88 cases, including successful-sign-in protection, unknown history, deletion limits, and changes detected before deletion. Earlier live validation used the Azure PowerShell 5.1 runtime. The unrelated `radiator/ConvertTo-Json` submodule has its own Pester 4 tests.

## Deployment and verification

A Git commit does not publish a runbook or change its schedule. There is no deployment automation added here. To update Azure, back up its published content and schedule binding, upload the revised file as a draft, test it, publish it, and verify the published content and job result. Check the schedule binding after publication because Azure can replace its binding ID.

The first three published hashes below match the source files at migration commit `3d01317`. Later comment changes alter local hashes without changing those runbooks. The guest hash matches the September 25 published update at commit `87b726f`:

| Script | SHA-256 |
| --- | --- |
| `Disable-StaleRegistrations.ps1` | `0c9d2fce619bd88746a837374408eca80f9a181dbf5c57e46cb7b362531ee56c` |
| `Assign-UserLicenses.ps1` | `302ee676ef51c8cca6f3f0ac36767fd45a6845a4563798615d3510aebb9597a9` |
| `Remove-LicensesFromDeletedUsers.ps1` | `7f5be2e517f2743442f6c8e15766c0ab6ff7052ba21635f3fd13307d6fd0109c` |
| `Remove-StaleGuests.ps1` | `3ed5bf74e12d25e710e7f22a2fa98ff1f76b935637c472eeaa533a94aefc79b2` |

At migration time, scheduled device runs and published jobs for the other three scripts completed successfully. The licensing Apply check needed no changes, so it did not exercise a real license or usage-location write. Local tests cover those write paths. Guest and deleted-user checks made no directory changes.

### September 25 guest-cleanup verification

- The live Preview read 51,571 audit records across all three required operations. Of 233 guests, 39 were eligible, 26 needed manual review, and 168 were protected by recent activity or dates.
- A fresh audit query was used for Apply. Job `c83af464-bdb1-4ca3-a7ed-4873d9203076` completed at 19:04 UTC. It deleted ten guests, skipped none after recheck, and deferred 29 under the limit.
- Independent reads confirmed all ten deleted IDs in Deleted users, all 168 protected guests still present, and all guests with unknown successful-sign-in history still present. No other guests were missing. There were 223 remaining guests at that check.
- Published content and the exact prior binding were backed up privately. The published content hash was checked against the committed source.
- Binding `b910a6b7-b93d-4f7a-acc2-f4c7e0fba7ea` was read back with `Mode=Apply` and `MaxDeletions=10`. The enabled `Daily` schedule still runs hourly at minute 52 in `America/Toronto`, with the same cloud worker. Other runbook bindings and the shared schedule were unchanged.
- The normal hourly trigger ran the published update in Preview and completed at 19:08 UTC without errors. This job had started before the binding changed to Apply.
- The next scheduled Apply run is September 25 at 15:52 Toronto time. The manual published Apply run is verified; a scheduled Apply run has not yet been observed.

Counts are snapshots. Each later Apply run makes a new decision from fresh audit and directory data.

Private tenant exports, review lists, tokens, and job logs are not part of this repository change.
