# Get Domain computers that are online by pinging them in parallel
Workflow Get-OnlineComputers
{
    param (
        [Parameter(Mandatory)]
        [object[]]$Computers
    )
    $up_computers = @()
    ForEach -Parallel ($computer in $Computers) {
        if (Test-Connection $computer.DNSHostName -Quiet) {
            $workflow:up_computers += $computer
        }
    }
    return $up_computers
}
$result = Get-OnlineComputers -Computers (Get-ADComputer -Filter "*"  -SearchBase "OU=WindowsUpdateEnforced,OU=Workstations SRP Blacklist,DC=main,DC=tbte,DC=ca")