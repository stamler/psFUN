# Get all jobs (projects or proposals) in a directory and the last write time of
# the most recently modified file in the job then output it to a CSV file. The
# edit time of the parent job folder is not considered.

$ageindays = 600;
$parentdir = “F:\projects\Proposals\2019”
$pattern = "P\d\d-\d{3,4}(-\d{1,3})?"
$output = @()
foreach($project in Get-ChildItem -Directory $parentdir | where-object {$_.name -match $pattern}) {
  $bytesize = 0
  $projsize = Get-ChildItem -Path $project.FullName -Recurse | Measure-Object -Sum Length | Select-Object Sum, Count
  if ($projsize.Count -gt 0) {
    # There are items in the project folder
    $bytesize = $projsize.Sum
    $newestitem = Get-ChildItem -Path $project.FullName -Recurse | sort LastWriteTime | select -last 1
    if ($project.LastWriteTime -gt $newestitem.LastWriteTime) {
      # The project folder itself is newer than the newest file in the project
      $newestitem = $project
    }
  } else {
    # There are no items in the project folder
    $newestitem = $project
  }
  if ($newestitem.LastWriteTime -lt (get-date).AddDays(-$ageindays)) {
    # The project is older than the ageindays
    $output += [PSCustomObject]@{
      job = $project.FullName
      time = $newestitem.LastWriteTime
      size = $bytesize
      count = $projsize.Count
    }
  }
}
$output | Export-Csv output.csv