<#
.SYNOPSIS
Archive stale jobs (projects or proposals) for one year from F: to the NAS.

.DESCRIPTION
Finds jobs in F:\projects\<Projects|Proposals>\<year> whose newest item is older
than -Age days. Without -Move it only reports them. With -Move it first checks
every job, shows how many are old enough and their total size, and asks before
doing anything. Then each old job is:

1. Renamed into ARCHIVE_STAGE in the year folder. This is instant, and it fails
   if anyone has a file in the job open, in which case the job is skipped.
2. Listed once. That listing is used to check that the job didn't change
   between the first check and the rename (a job that changed is put back), and
   later to verify the archive copy. Users can't open ARCHIVE_STAGE, so the job
   can't change after the rename.
3. Copied to \\nas2.main.tbte.ca\Archive\<type>\<year>\r\.
4. Compared with the copy: same files and folders, sizes and write times, and
   contents too with -VerifyHash.
5. Deleted from ARCHIVE_STAGE, only if the copy matches.

A job that fails a step stays on F: or in ARCHIVE_STAGE and is listed at the
end. A -Move run first finishes any jobs an earlier run left in ARCHIVE_STAGE.
A job is never moved or copied onto a folder that already exists, because that
would nest it inside the existing folder.

ARCHIVE_STAGE is created so that only the account running the script, SYSTEM
and Administrators can open it, and it's removed when a run leaves it empty.

A job's age comes from its newest file or folder, ignoring hidden and system
items such as Thumbs.db and desktop.ini, which change when people just browse.
The job folder's own write time counts only when the job has no visible files
or the folder is newer than everything in it. Copies and checks include every
item, hidden or not.

.EXAMPLE
.\Get-ArchiveList.ps1 -Year 2019
Report which 2019 projects would be archived.

.EXAMPLE
.\Get-ArchiveList.ps1 -Year 2019 -Proposals -Move
Archive 2019 proposals after confirming.

.NOTES
Run as TBTE\librarian, which needs delete rights on the job folders and write
access to the archive. Works in Windows PowerShell 5.1 and PowerShell 7.
Results are written to a CSV in the current folder. Run with -Help for flags.
#>


# The two blank lines above keep the help with the script, not this function
function Show-Usage {
  Write-Host @"

Usage: .\Get-ArchiveList.ps1 -Year <yyyy> [-Proposals] [-Move [-Yes]] [-Age <days>] [-VerifyHash]

  -Year <yyyy>   Year folder to archive, like 2019. Required.
  -Proposals     Archive proposals instead of projects.
  -Move          Archive the jobs. Without it, only report what would be archived.
  -Yes           With -Move, don't ask for confirmation.
  -Age <days>    Archive jobs with nothing changed in this many days. Default 400.
  -VerifyHash    Also compare file contents when checking copies. Slower.
  -Help          Show this message.

Flags can also be written with two dashes, like --Year 2019 --Move.

Examples:
  .\Get-ArchiveList.ps1 -Year 2019          Report 2019 projects that would be archived
  .\Get-ArchiveList.ps1 -Year 2019 -Move    Archive 2019 projects

"@
}

# What each status in the results means. Shown next to the counts at the end so
# nobody has to look the statuses up. Everything except Archived and DryRun is
# also listed under "Jobs that need attention".
$statusHelp = @{
  Archived = "Copied to the archive, checked, and removed from F:."
  DryRun = "Would be archived. Run with -Move to archive."
  ReadFailed = "Some of the job couldn't be read, so its age or copy can't be trusted. Left where it is."
  StageFailed = "Couldn't be moved into ARCHIVE_STAGE, usually because a file in it is open. Still on F:; try again later."
  DestinationExists = "A folder with this name is already in the archive. Still on F:; compare the two by hand."
  AlreadyStaged = "A folder with this name is already in ARCHIVE_STAGE. Still on F:."
  ModifiedRestored = "Changed just before staging, so it was put back on F:."
  ModifiedNotRestored = "Changed just before staging and couldn't be put back on F:. It's in ARCHIVE_STAGE; move it back by hand."
  CopyFailed = "Copying to the archive failed. It's in ARCHIVE_STAGE. Delete the partial copy in the archive, then run again."
  VerifyFailed = "The archive copy doesn't match. It's in ARCHIVE_STAGE. Delete the archive copy, then run again."
  DeleteFailed = "Archived and checked, but not fully removed from ARCHIVE_STAGE. The next -Move run finishes it."
}

# List everything under a folder in one pass, including hidden and system items,
# keyed by path relative to the folder (like "\sub\file.dwg"). The same listing
# is used to work out a job's age (Get-TreeStats) and to compare it with its
# archive copy (Compare-JobTrees), so each job is only read once per step.
# Errors (usually access denied) are collected rather than shown, and callers
# treat any error as "this listing can't be trusted".
function Get-TreeItems {
  Param([String]$Root)
  $rootItem = Get-Item -LiteralPath $Root -Force
  $rootPath = $rootItem.FullName.TrimEnd('\')
  $items = @{}
  $listErrors = @()
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable listErrors)) {
    $items[$item.FullName.Substring($rootPath.Length)] = $item
  }
  [PSCustomObject]@{ root = $rootItem; items = $items; errors = $listErrors }
}

# Size, file count and newest item of a job, from a Get-TreeItems listing.
# Hidden and system items, and anything inside a hidden or system folder, are
# ignored here. That matches what Get-ChildItem shows without -Force, and keeps
# files like Thumbs.db, which Windows updates when someone merely browses a
# folder, from making an old job look recently used.
function Get-TreeStats {
  Param($Tree)
  $separator = [IO.Path]::DirectorySeparatorChar
  $hiddenOrSystem = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
  $hiddenFolders = @($Tree.items.Keys | Where-Object {
    $Tree.items[$_].PsIsContainer -and [int]($Tree.items[$_].Attributes -band $hiddenOrSystem) -ne 0
  })
  $visible = @(foreach ($path in $Tree.items.Keys) {
    $item = $Tree.items[$path]
    if ([int]($item.Attributes -band $hiddenOrSystem) -ne 0) { continue }
    $insideHiddenFolder = $false
    foreach ($folder in $hiddenFolders) {
      if ($path.StartsWith($folder + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        $insideHiddenFolder = $true
        break
      }
    }
    if (!$insideHiddenFolder) { $item }
  })
  $files = @($visible | Where-Object { $_.PsIsContainer -eq $false })
  $stats = [PSCustomObject]@{
    size = 0
    count = $files.Count
    newest = $Tree.root
    projectFolderIsNewest = $true
    emptyFolder = ($files.Count -eq 0)
  }
  # With no visible files the job folder's own time is all there is to go on.
  # Otherwise the newest visible file or folder wins, unless the job folder
  # itself is newer still.
  if ($files.Count -gt 0) {
    $stats.size = ($files | Measure-Object -Sum Length).Sum
    $newestItem = $visible | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($Tree.root.LastWriteTime -le $newestItem.LastWriteTime) {
      $stats.newest = $newestItem
      $stats.projectFolderIsNewest = $false
    }
  }
  $stats
}

# List the differences between a staged job (as listed by Get-TreeItems before
# copying) and its archive copy: items missing from the copy, and files whose
# size, write time or (with -Hash) contents differ. An empty result means the
# copy is complete and the staged job can be deleted.
#
# With -AllowExtra, items that are only in the copy are fine. That's for
# finishing a job that an earlier run had already copied and then partly
# deleted from staging: what's left in staging only has to be in the copy.
function Compare-JobTrees {
  Param($SourceTree, [String]$Destination, [switch]$Hash, [switch]$AllowExtra)
  $src = $SourceTree
  $dst = Get-TreeItems $Destination
  $differences = @()
  # A folder that couldn't be listed could be hiding missing files, so it
  # always counts as a difference
  foreach ($listError in @($src.errors) + @($dst.errors)) {
    $differences += "Couldn't read $($listError.TargetObject)"
  }
  foreach ($path in $src.items.Keys) {
    $a = $src.items[$path]
    $b = $dst.items[$path]
    if ($null -eq $b) { $differences += "Missing from archive: $path"; continue }
    if ($a.PsIsContainer -ne $b.PsIsContainer) { $differences += "File in one, folder in the other: $path"; continue }
    # Folders only need to exist. Their write times change as the copy fills
    # them, so they aren't compared.
    if ($a.PsIsContainer) { continue }
    if ($a.Length -ne $b.Length) { $differences += "Different size: $path"; continue }
    # Copy-Item keeps each file's write time. Allow for file systems that store
    # write times to the nearest 2 seconds.
    if ([Math]::Abs(($a.LastWriteTimeUtc - $b.LastWriteTimeUtc).TotalSeconds) -gt 2) { $differences += "Different write time: $path"; continue }
    if ($Hash) {
      # A file that can't be hashed on either side counts as different
      $hashA = Get-FileHash -LiteralPath $a.FullName -ErrorAction SilentlyContinue
      $hashB = Get-FileHash -LiteralPath $b.FullName -ErrorAction SilentlyContinue
      if (!$hashA -or !$hashB -or $hashA.Hash -ne $hashB.Hash) { $differences += "Different contents: $path" }
    }
  }
  if (!$AllowExtra) {
    foreach ($path in $dst.items.Keys) {
      if (!$src.items.ContainsKey($path)) { $differences += "Not in staging: $path" }
    }
  }
  $differences
}

# Finish archiving a job that's in ARCHIVE_STAGE: check it hasn't changed, copy
# it to the archive unless an earlier run already did, check the copy, then
# delete the staged job. Problems are returned as a status, never thrown, and
# leave the job in staging, or back on F: if it changed.
#
# Returns the status, a detail message for the report, and the job's stats.
function Complete-StagedJob {
  Param([String]$Staged, [String]$Original, [String]$Destination, [int]$Age, [switch]$Hash)
  # List the staged job once. Nobody else can get into ARCHIVE_STAGE, so this
  # listing stays accurate for the age recheck and for verifying the copy.
  $tree = Get-TreeItems $Staged
  $result = [PSCustomObject]@{ status = ''; detail = ''; stats = (Get-TreeStats $tree) }
  if ($tree.errors.Count -gt 0) {
    $result.status = 'ReadFailed'
    $result.detail = @($tree.errors | ForEach-Object { "Couldn't read $($_.TargetObject)" }) -join ' | '
    return $result
  }

  # A copy already in the archive can only come from an earlier run of this
  # script, because jobs aren't staged when their archive folder exists. That
  # run already rechecked the job's age, so go straight to verifying.
  $copiedEarlier = Test-Path -LiteralPath $Destination
  if (!$copiedEarlier) {
    # Recheck the age. Someone may have saved a file after the first check and
    # before the rename. If so, the job is still in use, so put it back on F:
    # unless something else has taken its name there in the meantime.
    if ($result.stats.newest.LastWriteTime -ge (Get-Date).AddDays(-$Age)) {
      if (Test-Path -LiteralPath $Original) {
        $result.status = 'ModifiedNotRestored'
        $result.detail = "$Original already exists"
        return $result
      }
      try {
        Move-Item -LiteralPath $Staged -Destination $Original -ErrorAction Stop
        $result.status = 'ModifiedRestored'
      } catch {
        $result.status = 'ModifiedNotRestored'
        $result.detail = $_.Exception.Message
      }
      return $result
    }

    # The destination doesn't exist (checked above), so Copy-Item creates it
    # as a copy of the staged job rather than nesting the job inside it. -Force
    # makes it include hidden and system files.
    Write-Progress -Id 2 -ParentId 1 -Activity $Staged -Status 'Copying to the archive'
    $copyErrors = @()
    Copy-Item -LiteralPath $Staged -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable copyErrors
    if ($copyErrors.Count -gt 0 -or !(Test-Path -LiteralPath $Destination)) {
      $result.status = 'CopyFailed'
      $result.detail = @($copyErrors | ForEach-Object { $_.Exception.Message }) -join ' | '
      return $result
    }
  }

  # Compare the archive copy with the listing taken above. Only the first few
  # differences go in the report to keep it readable.
  Write-Progress -Id 2 -ParentId 1 -Activity $Staged -Status 'Checking the archive copy'
  $differences = @(Compare-JobTrees -SourceTree $tree -Destination $Destination -Hash:$Hash -AllowExtra:$copiedEarlier)
  if ($differences.Count -gt 0) {
    $result.status = 'VerifyFailed'
    $result.detail = @($differences | Select-Object -First 5) -join ' | '
    if ($differences.Count -gt 5) { $result.detail += " | and $($differences.Count - 5) more" }
    return $result
  }

  # The copy is good, so the staged job can go. If this stops partway, the
  # next run sees the archive copy, verifies what's left with -AllowExtra and
  # finishes the delete.
  Write-Progress -Id 2 -ParentId 1 -Activity $Staged -Status 'Deleting from staging'
  try {
    Remove-Item -LiteralPath $Staged -Recurse -Force -ErrorAction Stop
    $result.status = 'Archived'
  } catch {
    $result.status = 'DeleteFailed'
    $result.detail = $_.Exception.Message
  }
  $result
}

# Create ARCHIVE_STAGE so that only the account running this script, SYSTEM and
# Administrators can open it. Users can't browse into it, so staged jobs can't
# change, and a job vanishing from the year folder is the only sign of it.
#
# This is one icacls call on a new, empty folder, so it's instant. Staged jobs
# keep their own permissions; nothing is reset on the files inside them.
# Accounts are given as SIDs so this works whatever language Windows is in:
# S-1-5-18 is SYSTEM and S-1-5-32-544 is Administrators. icacls is used rather
# than Set-Acl because Set-Acl also rewrites the folder's owner, which fails
# for accounts that aren't administrators.
function New-StagingFolder {
  Param([String]$Path)
  New-Item -ItemType Directory -Path $Path | Out-Null
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  # /inheritance:r drops the permissions inherited from the year folder, and
  # /grant:r replaces any existing entries for these accounts. (OI)(CI)F is full
  # control for the folder and everything later put in it.
  $icaclsOutput = icacls $Path /inheritance:r /grant:r "*${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
  if ($LASTEXITCODE -ne 0) {
    # Never stage jobs in a folder users might be able to open
    Remove-Item -LiteralPath $Path
    throw "Couldn't set permissions on ${Path}: $icaclsOutput"
  }
}

# One row of the CSV report. The columns before status match what the script
# reported before staging was added.
function New-ReportRow {
  Param([String]$Job, $Stats, [String]$Status, [String]$Detail)
  [PSCustomObject]@{
    job = $Job
    time = $Stats.newest.LastWriteTime
    size = $Stats.size
    count = $Stats.count
    projectFolderIsNewest = $Stats.projectFolderIsNewest
    emptyFolder = $Stats.emptyFolder
    daysOld = (New-TimeSpan -Start $Stats.newest.LastWriteTime -End (Get-Date)).Days
    status = $Status
    detail = $Detail
  }
}

# ---------------------------------------------------------------------------
# Read the flags
# ---------------------------------------------------------------------------

# There's no param block on purpose. With one, PowerShell rejects an unknown or
# malformed flag with its own error before any of this code runs. Reading
# $args by hand means every mistake gets a plain message plus the usage, and
# --Flag works as well as -Flag. All problems are collected and shown together.
$argv = @($args)
$Year = ''
$ageText = $null
$Proposals = $false
$Move = $false
$Yes = $false
$VerifyHash = $false
$problems = @()
for ($i = 0; $i -lt $argv.Count; $i++) {
  $arg = "$($argv[$i])"
  # Accept -Flag or --Flag, in any case. -Year:2019 arrives as '-Year:' then
  # 2019, so a trailing colon is dropped too.
  $flag = $arg -replace '^--?', '' -replace ':$', ''
  if ($arg -notmatch '^--?[A-Za-z]') {
    $problems += "Unexpected '$arg'."
  } elseif ($flag -in 'Year', 'Age') {
    # These take a value. If the next argument is another flag, the value is
    # missing, and that flag is left to be read on the next pass of the loop.
    if ($i + 1 -ge $argv.Count -or "$($argv[$i + 1])" -match '^--?[A-Za-z]') {
      $problems += "-$flag needs a value."
    } else {
      $i++
      if ($flag -eq 'Year') { $Year = "$($argv[$i])" } else { $ageText = "$($argv[$i])" }
    }
  } elseif ($flag -eq 'Proposals') {
    $Proposals = $true
  } elseif ($flag -eq 'Move') {
    $Move = $true
  } elseif ($flag -eq 'Yes') {
    $Yes = $true
  } elseif ($flag -eq 'VerifyHash') {
    $VerifyHash = $true
  } elseif ($flag -in 'Help', 'h') {
    Show-Usage
    exit 0
  } else {
    $problems += "Unknown flag '$arg'."
  }
}
if (!$Year) {
  $problems += "-Year is required."
} elseif ($Year -notmatch '^\d{4}$') {
  $problems += "'$Year' isn't a year. Use four digits, like 2019."
}
$Age = 400
if ($null -ne $ageText) {
  $parsedAge = 0
  if (![int]::TryParse($ageText, [ref]$parsedAge) -or $parsedAge -lt 1) {
    $problems += "-Age must be a whole number of days, like 400."
  } else {
    $Age = $parsedAge
  }
}
if ($Yes -and !$Move) {
  $problems += "-Yes only applies with -Move."
}
if ($problems.Count -gt 0) {
  foreach ($problem in $problems) { Write-Host $problem -ForegroundColor Red }
  Show-Usage
  exit 1
}

# ---------------------------------------------------------------------------
# Work out the folders and check they're there
# ---------------------------------------------------------------------------

$jobType = if ($Proposals) { "Proposals" } else { "Projects" }
$parentdir = "F:\projects\$jobType\$Year"
# The archive mirrors the year folder, with the jobs one level down in r\
$destination = "\\nas2.main.tbte.ca\Archive\$jobType\$Year\r"
if (!(Test-Path -LiteralPath $parentdir)) {
  Write-Host "Can't find $parentdir." -ForegroundColor Red
  exit 1
}
# Staging sits in the year folder so it's on the same volume as the jobs. That
# makes moving a job into it a rename rather than a copy.
$stage = Join-Path $parentdir 'ARCHIVE_STAGE'
if ($Move -and !(Test-Path -LiteralPath "\\nas2.main.tbte.ca\Archive\$jobType")) {
  Write-Host "Can't reach \\nas2.main.tbte.ca\Archive\$jobType." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
# Pass 1: find the jobs old enough to archive
# ---------------------------------------------------------------------------

# Job folders are named like 19-123 or 19-123-4 (proposals start with P). This
# also keeps ARCHIVE_STAGE out of the list.
$pattern = if ($jobType -eq 'Projects') { "\d\d-\d{3,4}(-\d{1,3})?" } else { "P\d\d-\d{3,4}(-\d{1,3})?" }
$projects = @(Get-ChildItem -Directory -LiteralPath $parentdir | Where-Object { $_.Name -match $pattern })
$cutoff = (Get-Date).AddDays(-$Age)
$output = @()
$candidates = @()
$itemNumber = 0
foreach ($project in $projects) {
  $itemNumber++
  Write-Progress -Id 1 -Activity "Checking $Year $jobType" -Status $project.FullName -PercentComplete ([int]($itemNumber * 100 / $projects.Count))
  $tree = Get-TreeItems $project.FullName
  $stats = Get-TreeStats $tree
  if ($tree.errors.Count -gt 0) {
    # Part of the job couldn't be read, so its age is unknown. Report it and
    # leave it alone, whatever its readable files say.
    $detail = @($tree.errors | ForEach-Object { "Couldn't read $($_.TargetObject)" }) -join ' | '
    $output += New-ReportRow $project.FullName $stats 'ReadFailed' $detail
  } elseif ($stats.newest.LastWriteTime -lt $cutoff) {
    # Keep only the stats. The listing is taken again after staging, because
    # the job can change between now and then.
    $candidates += [PSCustomObject]@{ project = $project; stats = $stats }
  }
}
Write-Progress -Id 1 -Activity "Checking $Year $jobType" -Completed
# Jobs left in staging by a run that was interrupted or hit a problem
$leftovers = @(if (Test-Path -LiteralPath $stage) { Get-ChildItem -Directory -LiteralPath $stage })

$totalSize = ($candidates | ForEach-Object { $_.stats.size } | Measure-Object -Sum).Sum
Write-Host ("{0} of {1} jobs in {2} have had no changes in {3} days ({4:N1} GB)." -f $candidates.Count, $projects.Count, $parentdir, $Age, ($totalSize / 1GB))
if ($leftovers.Count -gt 0) {
  Write-Host "$($leftovers.Count) more were left in $stage by an earlier run."
}

if (!$Move) {
  # Dry run: report and stop
  foreach ($candidate in $candidates) {
    $output += New-ReportRow $candidate.project.FullName $candidate.stats 'DryRun' ''
  }
} else {
  if ($candidates.Count + $leftovers.Count -eq 0) {
    Write-Host "Nothing to archive."
    exit 0
  }
  if (!$Yes) {
    $answer = Read-Host "Archive them to ${destination}? (y/N)"
    # Read-Host returns $null when there's no input, and $null -notmatch is
    # false, so compare as a string to make no answer mean no
    if ("$answer".Trim() -notmatch '^(y|yes)$') {
      Write-Host "Nothing was moved."
      exit 0
    }
  }
  if (!(Test-Path -LiteralPath $destination)) {
    New-Item -ItemType Directory -Path $destination | Out-Null
  }
  if (!(Test-Path -LiteralPath $stage)) {
    New-StagingFolder $stage
  }

  # -------------------------------------------------------------------------
  # Finish what an earlier run left in staging before staging anything new
  # -------------------------------------------------------------------------

  foreach ($staged in $leftovers) {
    $original = Join-Path $parentdir $staged.Name
    $result = Complete-StagedJob -Staged $staged.FullName -Original $original -Destination (Join-Path $destination $staged.Name) -Age $Age -Hash:$VerifyHash
    Write-Progress -Id 2 -Activity $staged.FullName -Completed
    $detail = (@('Left in ARCHIVE_STAGE by an earlier run', $result.detail) | Where-Object { $_ }) -join '. '
    $output += New-ReportRow $original $result.stats $result.status $detail
  }

  # -------------------------------------------------------------------------
  # Pass 2: stage and archive each old job
  # -------------------------------------------------------------------------

  $itemNumber = 0
  foreach ($candidate in $candidates) {
    $itemNumber++
    $project = $candidate.project
    Write-Progress -Id 1 -Activity "Archiving $Year $jobType" -Status $project.FullName -PercentComplete ([int]($itemNumber * 100 / $candidates.Count))
    $staged = Join-Path $stage $project.Name
    $destJob = Join-Path $destination $project.Name
    $status = ''
    $detail = ''
    # Moving or copying a folder onto an existing one would nest it inside, so
    # skip jobs whose name is already taken in staging or the archive
    if (Test-Path -LiteralPath $destJob) {
      $status = 'DestinationExists'
      $detail = "$destJob already exists"
    } elseif (Test-Path -LiteralPath $staged) {
      $status = 'AlreadyStaged'
      $detail = "$staged already exists"
    } else {
      # Same volume, so this is a rename: all or nothing, and Windows refuses
      # it while anything in the job is open
      try {
        Move-Item -LiteralPath $project.FullName -Destination $staged -ErrorAction Stop
      } catch {
        $status = 'StageFailed'
        $detail = $_.Exception.Message
      }
      if (!$status) {
        $result = Complete-StagedJob -Staged $staged -Original $project.FullName -Destination $destJob -Age $Age -Hash:$VerifyHash
        Write-Progress -Id 2 -Activity $staged -Completed
        $status = $result.status
        $detail = $result.detail
      }
    }
    # The report shows the job as it was in pass 1
    $output += New-ReportRow $project.FullName $candidate.stats $status $detail
  }
  Write-Progress -Id 1 -Activity "Archiving $Year $jobType" -Completed

  # Don't leave an empty folder in the year folder that users can't open
  if ((Test-Path -LiteralPath $stage) -and !(Get-ChildItem -LiteralPath $stage -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $stage
  }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

if ($output.Count -eq 0) {
  exit 0
}
$csvPath = $(Get-Location).Path + "\$Year-$jobType-" + $(Get-Date -Format "yyyy-MM-dd HH-mm") + $(if ($Move) { " Archive" } else { " DryRun" }) + ".csv"
$output | Export-Csv -Path $csvPath

# A count for each status with what it means, then every job that needs a look
Write-Host ""
foreach ($group in ($output | Group-Object status)) {
  Write-Host ("{0,5}  {1,-20} {2}" -f $group.Count, $group.Name, $statusHelp[$group.Name])
}
$attention = @($output | Where-Object { $_.status -notin 'Archived', 'DryRun' })
if ($attention.Count -gt 0) {
  Write-Host "`nJobs that need attention:" -ForegroundColor Yellow
  foreach ($row in $attention) {
    Write-Host "  $($row.job) [$($row.status)] $($row.detail)"
  }
}
Write-Host "`nResults saved to $csvPath"

# TODO: Sanity check by verifying that there is no overlap between the jobs in
# the destination folder and the jobs in parentdir

# Exit code 2 tells a caller that some jobs need attention
if ($attention.Count -gt 0) {
  exit 2
}
