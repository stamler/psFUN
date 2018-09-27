$t_size = $t_count = 0
$t_tmp_size = $t_tmp_count = 0
$t_tilde_size = $t_tilde_count = 0
$t_dsstore_size = $t_dsstore_count = 0
$t_thumbs_size = $t_thumbs_count = 0
$t_bak_size = $t_bak_count = 0
$t_lnk_size = $t_lnk_count = 0

Get-ChildItem -Path . -Include Thumbs.db,.DS_Store,~*,*.tmp,*.bak,*.lnk -Recurse -Force | ForEach-Object { 
  $t_count +=1; 
  $t_size += $_.length; 
  '{0,10} {1,4}' -f $_.Length, $_.Name

  if ($_.Name -eq 'Thumbs.db') { $t_thumbs_count += 1; $t_thumbs_size += $_.Length }
  elseif ($_.Name -eq '.DS_Store') { $t_dsstore_count += 1; $t_dsstore_size += $_.Length }
  elseif ($_.Name -match '\.tmp$') { $t_tmp_count += 1; $t_tmp_size += $_.Length }
  elseif ($_.Name -match '\.lnk$') { $t_lnk_count += 1; $t_lnk_size += $_.Length }
  elseif ($_.Name -match '\.bak$') { $t_bak_count += 1; $t_bak_size += $_.Length }
  elseif ($_.Name -match '^~') { $t_tilde_count += 1; $t_tilde_size += $_.Length }
}

'Found {0} matching files with total size of {1} bytes' -f $t_count, $t_size
'Thumbs.db {0} files occupy {1} bytes' -f $t_thumbs_count, $t_thumbs_size
'.DS_Store {0} files occupy {1} bytes' -f $t_dsstore_count, $t_dsstore_size
'*.tmp     {0} files occupy {1} bytes' -f $t_tmp_count, $t_tmp_size
'*.lnk     {0} files occupy {1} bytes' -f $t_lnk_count, $t_lnk_size
'*.bak     {0} files occupy {1} bytes' -f $t_bak_count, $t_bak_size
'~*        {0} files occupy {1} bytes' -f $t_tilde_count, $t_tilde_size
