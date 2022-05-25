# Get all jobs (projects or proposals) in a directory and the last write time of
# the most recently modified file in the job then output it to a CSV file. The
# edit time of the parent job folder is not considered.

param(
  [String]$Year = 2018,
  [switch]$Proposals = $false,
  [int]$Age = 600,
  [switch]$Move = $false
);

$ageindays = $Age
$year = $Year
$jobType = if ($Proposals) { "Proposals" } else { "Projects" }
$moveitems = $Move

$destination = "\\nas2.main.tbte.ca\Archive\$jobType\$year\r\"
# Create the folder if it doesn't exist
if (!(Test-Path $destination)) {
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
  Write-Progress -Id 1 -Activity Archiving -Status $project.FullName -PercentComplete $percentComplete -CurrentOperation "Analyzing"
  $bytesize = 0
  $reportString = "---`r`n$($project.FullName)`r`n"
  $projsize = Get-ChildItem -Path $project.FullName -Recurse | Where-Object { $_.PsIsContainer -eq $false }| Measure-Object -Sum Length | Select-Object Sum, Count
  if ($projsize.Count -gt 0) {
    $reportString += "There are $($projsize.Count) items totalling $($projsize.Sum) bytes in the project folder"
    $bytesize = $projsize.Sum
    $newestitem = Get-ChildItem -Path $project.FullName -Recurse | sort LastWriteTime | select -last 1
    if ($project.LastWriteTime -gt $newestitem.LastWriteTime) {
      $reportString += "`r`nThe project folder itself is newer than the newest file in the project"
      $newestitem = $project
    }
  } else {
    $reportString += "This folder is empty so the date of the folder is being used"
    # There are no items in the project folder
    $newestitem = $project
  }
  if ($newestitem.LastWriteTime -lt (get-date).AddDays(-$ageindays)) {
    $timeSpan = New-TimeSpan -End $(get-date) -Start $newestitem.LastWriteTime
    $reportString += "`r`nNo edits have been performed in $($timeSpan.Days) days`r`n"
    $output += [PSCustomObject]@{
      job = $project.FullName
      time = $newestitem.LastWriteTime
      size = $bytesize
      count = $projsize.Count
    }
    if ($moveitems -eq $true) {
      # Move the job to the staging area in the archive
      Write-Progress -Id 1 -Activity Archiving -Status $project.FullName -PercentComplete $percentComplete -CurrentOperation "Moving"
      $moveErrorsCount = $moveErrors.Count
      Move-Item -Path $project.FullName -Destination $destination -ErrorAction SilentlyContinue -ErrorVariable +moveErrors
      if ($moveErrors.Count -gt $moveErrorsCount) {
        $reportString += "`r`nThere were error(s) moving the folder to the archive"
        $jobsWithErrors += $project.FullName
      }
      $reportString += "Item moved"
    } else {
      $reportString += "Dry Run: $($project.FullName) > $destination"
    }
  } else {
    $reportString += "`r`nThe folder was edited within the last $ageindays days"
  }
  Write-Host $reportString
}
if ($moveErrors.Count -gt 0) {
  Write-Output "`r`nMove-Item Errors Unique TargetObjects:"
  Write-Output $jobsWithErrors | Sort-Object -Unique
  # TODO: TargetObject only contains the file name, not the full path.
  # We must have the full path to the file in order to remediate the error.
  Write-Output $moveErrors | Select-Object -Property TargetObject -Unique
} else {
  Write-Output "No move errors"
}
$csvPath = $(Get-Location).Path + "\$year-$jobType-" + $(Get-Date -Format "yyyy-MM-dd HH-mm") + $(if ($moveitems -eq $true) { " Archive" } else { " DryRun" }) + ".csv"
$output | Export-Csv -Path $csvPath 
