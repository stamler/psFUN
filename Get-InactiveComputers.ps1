# $result contains AD computers inactive for at least 60 days 

$DaysInactive = 60
$time = (Get-Date).Adddays(-($DaysInactive))
$result = Get-ADComputer -Filter {LastLogonTimeStamp -lt $time}