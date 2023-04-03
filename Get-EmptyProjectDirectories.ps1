# This script will get a list of empty directories in a project directory
# and write them to a CSV file. It will also delete the empty directories
# if the -Delete parameter is specified.
# Dean Stamler (2023-03-21)

# Parameters are the year of the project and the -Delete parameter
[CmdletBinding()]
Param(
  [Parameter(Mandatory=$true)]
  [string]$Year,
  [switch]$Delete
)

# Set the path to the current directory
$proj_root = "Y:\Projects"

# The directory is the project root plus the year
$directory = "$proj_root\$Year"

# Set the variable for the year. The last two digits of the year will be
# extracted for filtering purposes
# get the last two digits of the year
$XX = $Year.Substring(2,2)

# Set a pass-number variable
$pass = 1

# Run the following code once. If the $emptyDirectories variable is not empty,
# loop and run the code again until it is empty.
do {
  # Get a list of all empty directories in the specified directory, excluding
  # those at the root and those where the deepest directory begins with the
  # pattern XX-YYY
  $emptyDirectories = Get-ChildItem $directory -Recurse | Where-Object {$_.PSIsContainer -and @(Get-ChildItem $_.FullName -Force).Count -eq 0 -and ($_.FullName -notlike "$directory/$XX-*") -and ($_.FullName.Split("\")[-1] -notlike "$XX-*")} | ForEach-Object {
    $currentDirectory = $_.FullName
    Write-Progress -Activity "Getting empty directories (pass ${pass})..." -Status $currentDirectory
    return $_
  }
  # Audit the result
  Write-Host "Auditing $($emptyDirectories.Count) empty directories in $directory..."
  foreach ($item in $emptyDirectories) {
    Write-Progress -Activity "Auditing $($item.FullName)" -Status "Progress" -PercentComplete (($emptyDirectories.IndexOf($item) + 1) / $emptyDirectories.Count * 100)
    if ((Get-ChildItem -Path $item.FullName | Measure-Object).Count -gt 0) {
      Write-Output "$item.FullName is not empty"
      Write-Output "Exiting..."
      Exit 1
    }
  }

  # if the -Delete parameter is specified, the script will delete the empty
  # directories, otherwise it will only write the CSV file.
  if ($Delete) {
    # Write the list of empty directories to a CSV file
    $emptyDirectories | Select-Object FullName | Export-Csv -Path "empty_directories_${Year}_pass${pass}.csv" -NoTypeInformation
    # Delete the empty directories
    $emptyDirectories | Remove-Item -Recurse | ForEach-Object {
      $currentDirectory = $_.FullName
      Write-Progress -Activity "Deleting empty directories (pass ${pass})..." -Status $currentDirectory
    }
  } else {
    # Write the list of empty directories to a CSV file
    $emptyDirectories | Select-Object FullName | Export-Csv -Path "empty_directories_${Year}_DryRun.csv" -NoTypeInformation
  }

  # Increment the pass number
  $pass++
} while (
  $emptyDirectories.Count -gt 0 -and $Delete -eq $true
)