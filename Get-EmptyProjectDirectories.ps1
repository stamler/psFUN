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

# Get a list of all empty directories in the specified directory, excluding
# those at the root and those where the deepest directory begins with the
# pattern XX-YYY
$emptyDirectories = Get-ChildItem $directory -Recurse | Where-Object {$_.PSIsContainer -and @(Get-ChildItem $_.FullName -Force).Count -eq 0 -and ($_.FullName -notlike "$directory/$XX-*") -and ($_.FullName.Split("\")[-1] -notlike "$XX-*")}

# if the -Delete parameter is specified, the script will delete the empty
# directories, otherwise it will only write the CSV file.
if ($Delete) {
    # Write the list of empty directories to a CSV file
    $emptyDirectories | Select-Object FullName | Export-Csv -Path "empty_directories_$Year.csv" -NoTypeInformation
    # Delete the empty directories
    $emptyDirectories | Remove-Item -Recurse -Confirm
  } else {
    # Write the list of empty directories to a CSV file
    $emptyDirectories | Select-Object FullName | Export-Csv -Path "empty_directories_$Year.csv" -NoTypeInformation
}
