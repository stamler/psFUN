# Find and delete items in the current directory recursively that
# match the following patterns:
#   Thumbs.db
#   .DS_Store
#   ~*
#   *.tmp
#   *.bak
#   *.lnk
#
# This code doesn't distinguish between folders and files
# Since the Remove-Item command doesn't specify -Recurse it will prompt
# when it happens upon a non-empty directory. The user should determine the
# appropriate action

$t_size = $t_count = 0
$t_tmp_size = $t_tmp_count = 0
$t_tilde_size = $t_tilde_count = 0
$t_dsstore_size = $t_dsstore_count = 0
$t_thumbs_size = $t_thumbs_count = 0
$t_bak_size = $t_bak_count = 0
$t_lnk_size = $t_lnk_count = 0
# $csv_name = 'clean-{0}.csv' -f (Get-Date -format "yyyy-MM-dd_HH:mm")

Get-ChildItem -Path . -Include Thumbs.db,.DS_Store,~*,*.tmp,*.bak,*.lnk -Recurse -Force | ForEach-Object { 
  $t_count +=1; 
  $t_size += $_.length; 
  '{0},{1}' -f $_.Length, $_.FullName

  if ($_.Name -eq 'Thumbs.db') { $t_thumbs_count += 1; $t_thumbs_size += $_.Length }
  elseif ($_.Name -eq '.DS_Store') { $t_dsstore_count += 1; $t_dsstore_size += $_.Length }
  elseif ($_.Name -match '\.tmp$') { $t_tmp_count += 1; $t_tmp_size += $_.Length }
  elseif ($_.Name -match '\.lnk$') { $t_lnk_count += 1; $t_lnk_size += $_.Length }
  elseif ($_.Name -match '\.bak$') { $t_bak_count += 1; $t_bak_size += $_.Length }
  elseif ($_.Name -match '^~') { $t_tilde_count += 1; $t_tilde_size += $_.Length }

  Remove-Item $_ -Force
}

'Found {0} matching files with total size of {1} bytes' -f $t_count, $t_size
'Thumbs.db {0} files occupy {1} bytes' -f $t_thumbs_count, $t_thumbs_size
'.DS_Store {0} files occupy {1} bytes' -f $t_dsstore_count, $t_dsstore_size
'*.tmp     {0} files occupy {1} bytes' -f $t_tmp_count, $t_tmp_size
'*.lnk     {0} files occupy {1} bytes' -f $t_lnk_count, $t_lnk_size
'*.bak     {0} files occupy {1} bytes' -f $t_bak_count, $t_bak_size
'~*        {0} files occupy {1} bytes' -f $t_tilde_count, $t_tilde_size
