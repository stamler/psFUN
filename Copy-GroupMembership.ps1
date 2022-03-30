#Copy members from a security group to a Microsoft 365 Group

#Connect
Connect-AzureAD
Connect-ExchangeOnline

#Show Security Groups
Get-AzureADGroup -Filter "SecurityEnabled eq true" | Select DisplayName,MailEnabled,ObjectId
Get-UnifiedGroup | Select DisplayName, Guid

$sourceGroupOid = "d41358c6-aab2-48bb-bef1-18a15267badc"
$destinationGuid = "7f1ab1ab-d8f2-4162-8bb6-0d0fd7d263b4"

# Get members of chosen group
$userEmails = Get-AzureADGroupMember -ObjectId $sourceGroupOid | ForEach-Object { $_.Mail }
Add-UnifiedGroupLinks -Identity $destinationGuid -Links $userEmails -LinkType Members -WhatIf
