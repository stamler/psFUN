# Return enabled user accounts that haven't signed in within 90 days

Search-ADAccount –AccountInActive –TimeSpan 90:00:00:00 -UsersOnly | ?{$_.Enabled –eq $True} | Sel
ect-Object Name