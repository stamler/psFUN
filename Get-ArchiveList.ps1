# Get all jobs (projects or proposals) in a directory and the last write time of
# the most recently modified file in the job then output it to a CSV file. The
# edit time of the parent job folder is not considered.

$ageindays = 600
$moveitems = $false
$destination = "\\nas2.main.tbte.ca\Archive\Projects\2018\r\"
$parentdir = “F:\projects\Projects\2018”
#$pattern = "P\d\d-\d{3,4}(-\d{1,3})?"
$pattern = "\d\d-\d{3,4}(-\d{1,3})?"
$output = @()
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
      Move-Item -Path $project.FullName -Destination $destination
      $reportString += "Item moved"
    } else {
      $reportString += "Dry Run: $($project.FullName) > $destination"
    }
  } else {
    $reportString += "`r`nThe folder was edited within the last $ageindays days"
  }
  Write-Host $reportString
}
$output | Export-Csv output.csv 
