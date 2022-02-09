$Groups = Get-ADGroup -Filter * -SearchBase 'OU=Groups,DC=main,DC=tbte,DC=ca’
$Results = foreach( $Group in $Groups ){
  Get-ADGroupMember -Identity $Group | foreach {
    [pscustomobject]@{
      GroupName = $Group.Name
      Name = $_.Name
    }
  }
}
$Results | Export-Csv -path GroupMembership.csv
