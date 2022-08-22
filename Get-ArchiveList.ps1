# Get all jobs (projects or proposals) in a directory and the last write time of
# the most recently modified file in the job then output it to a CSV file. The
# edit time of the parent job folder is not considered.

function Archive-Jobs {
  Param(
    [Parameter(Mandatory=$true)]
    [String]$Year,
    [switch]$Proposals = $false,
    [int]$Age = 400,
    [switch]$Move = $false
  )

  $year = $Year
  $jobType = if ($Proposals) { "Proposals" } else { "Projects" }
  $moveitems = $Move

  $destination = "\\nas2.main.tbte.ca\Archive\$jobType\$year\r\"
  # Create the folder if it doesn't exist
  if (!(Test-Path $destination) -and $moveitems) {
    New-Item -ItemType Directory -Path $destination
  }

  $parentdir = “F:\projects\$jobType\$year”
  $pattern = if ($jobType -eq 'Projects') { "\d\d-\d{3,4}(-\d{1,3})?" } else { "P\d\d-\d{3,4}(-\d{1,3})?" }
  $output = @()
  $jobsWithErrors = @()
  $projects = Get-ChildItem -Directory $parentdir | where-object {$_.name -match $pattern}
  $folderCount = ($projects | Measure-Object).Count
  $itemNumber = 0
  foreach($project in $projects) {
    $itemNumber ++
    $percentComplete = [int]($itemNumber * 100 / $folderCount)
    Write-Progress -Id 1 -Activity "Archiving $year $jobType" -Status $project.FullName -PercentComplete $percentComplete -CurrentOperation "Analyzing"
    $bytesize = 0
    $projsize = Get-ChildItem -Path $project.FullName -Recurse | Where-Object { $_.PsIsContainer -eq $false }| Measure-Object -Sum Length | Select-Object Sum, Count
    if ($projsize.Count -gt 0) {
      $emptyFolder = $false
      $bytesize = $projsize.Sum
      $newestitem = Get-ChildItem -Path $project.FullName -Recurse | sort LastWriteTime | select -last 1
      $projectFolderIsNewest = $false
      if ($project.LastWriteTime -gt $newestitem.LastWriteTime) {
        $projectFolderIsNewest = $true
        $newestitem = $project
      }
    } else {
      $emptyFolder = $true
      $projectFolderIsNewest = $true
      # There are no items in the project folder
      $newestitem = $project
    }
    if ($newestitem.LastWriteTime -lt (get-date).AddDays(-$Age)) {
      $timeSpan = New-TimeSpan -End $(get-date) -Start $newestitem.LastWriteTime
      $daysOld = $timeSpan.Days
      $moveErrorsEncountered = 0
      if ($moveitems -eq $true) {
        # Move the job to the staging area in the archive
        Write-Progress -Id 1 -Activity "Archiving $year $jobType" -Status $project.FullName -PercentComplete $percentComplete -CurrentOperation "Moving"
        $moveErrorsCount = $moveErrors.Count
        Move-Item -Path $project.FullName -Destination $destination -ErrorAction SilentlyContinue -ErrorVariable +moveErrors
        if ($moveErrors.Count -gt $moveErrorsCount) {
          $moveErrorsEncountered = $moveErrors.Count - $moveErrorsCount
          $jobsWithErrors += $project.FullName
        }
      }
      $output += [PSCustomObject]@{
        job = $project.FullName
        time = $newestitem.LastWriteTime
        size = $bytesize
        count = $projsize.Count
        projectFolderIsNewest = $projectFolderIsNewest
        emptyFolder = $emptyFolder
        daysOld = $daysOld
        moveErrorsEncountered = $moveErrorsEncountered
      }
    }
  }
  if ($moveErrors.Count -gt 0) {
    # TargetObject only contains the file name, not the full path.
    # We must have the full path to the file in order to remediate the error.
    Write-Output "Move-Item unique jobs with errors:"
    Write-Output $jobsWithErrors | Sort-Object -Unique
    Write-Output "Move-Item unique TargetObjects with errors:"
    Write-Output $moveErrors | Select-Object -Property TargetObject -Unique
  }
  $csvPath = $(Get-Location).Path + "\$year-$jobType-" + $(Get-Date -Format "yyyy-MM-dd HH-mm") + $(if ($moveitems -eq $true) { " Archive" } else { " DryRun" }) + ".csv"
  $output | Export-Csv -Path $csvPath

  # TODO: Sanity check by verifying that there is no overlap between the jobs in
  # the destination folder and the jobs in parentdir
}

Archive-Jobs -Year 2015
