# Get all jobs (projects or proposals) in a directory and the last write time of
# the most recently modified file in the job then output it to a CSV file. The
# edit time of the parent job folder is not considered.

$parentdir = “F:\projects\Proposals\2019”
$pattern = "P\d\d-\d{3,4}(-\d{1,3})?"
$output = @()
foreach($project in Get-ChildItem -Directory $parentdir | where-object {$_.name -match $pattern}) {
  $newestitem = Get-ChildItem $project.FullName | sort LastWriteTime | select -last 1
  $output += [PSCustomObject]@{
    project = $project.FullName
    time = $newestitem.LastWriteTime
  }
}
$output | Export-Csv output.csv