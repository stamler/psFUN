[CmdletBinding()]
param (
  [Parameter()]
  [String]
  $l2tppsk
)

$ConnectionName = "TBT Engineering Limited L2TP"
$server = "vpn.tbte.ca"

function Write-LogEntry {
  param (
      [parameter(Mandatory = $true)]
      [ValidateNotNullOrEmpty()]
      [string]$Value,
      [parameter(Mandatory = $false)]
      [ValidateNotNullOrEmpty()]
      [string]$FileName = "$($ConnectionName).log",
      [switch]$Stamp
  )

  #Build Log File appending System Date/Time to output
  $LogFile = Join-Path -Path $env:SystemRoot -ChildPath $("Temp\$FileName")
  $Time = -join @((Get-Date -Format "HH:mm:ss.fff"), " ", (Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias))
  $Date = (Get-Date -Format "MM-dd-yyyy")

  If ($Stamp) {
      $LogText = "<$($Value)> <time=""$($Time)"" date=""$($Date)"">"
  }
  else {
      $LogText = "$($Value)"   
  }

  Try {
      Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFile -ErrorAction Stop
  }
  Catch [System.Exception] {
      Write-Warning -Message "Unable to add log entry to $LogFile.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
  }
}


try {
  Add-VpnConnection -Name $ConnectionName -ServerAddress $server -AllUserConnection -TunnelType "L2tp" -L2tpPsk $l2tppsk -EncryptionLevel "Required" -AuthenticationMethod "Chap","MSChapv2" -Force
  Write-LogEntry -Stamp -Value "Created L2TP connection $($ConnectionName)"
}
catch [Microsoft.Management.Infrastructure.CimException] {
  Write-LogEntry -Stamp -Value "Connection already exists, rewriting values"
  Set-VpnConnection -Name $ConnectionName -ServerAddress $server -AllUserConnection -TunnelType "L2tp" -L2tpPsk $l2tppsk -EncryptionLevel "Required" -AuthenticationMethod "Chap","MSChapv2" -Force
}