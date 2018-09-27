$totalsize = 0
$totalcount = 0
Get-ChildItem -Path . -Include Thumbs.db,.DS_Store,~*,*.tmp,*.bak,*.lnk -Recurse -Force | ForEach-Object { 
  $totalcount +=1; 
  $totalsize+=$_.length; 
  '{0,10} {1,4}' -f $_.length, $_.name
}
'Found {0} matching files with total size of {1} bytes' -f $totalcount, $totalsize