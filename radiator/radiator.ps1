# PS v2.0 compatible
# PS v3.0 and later: Get-CimInstance replaces Get-WmiObject
# Assumes that the Azure AD Connect sourceAnchor is ms-DS-ConsistencyGuid

$dyle_endpoint = "https://us-central1-charade-ca63f.cloudfunctions.net/rawLogins"

# Get the Data
$c_bios = Get-WmiObject Win32_Bios
$c_os = Get-WmiObject Win32_OperatingSystem
$c_system = Get-WmiObject Win32_ComputerSystem
$c_volume = Get-WmiObject Win32_Volume -Filter "BootVolume = True"
$c_netset = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True"

# Build the Report
$user_info_source = ([ADSI]"LDAP://<SID=$([System.Security.Principal.WindowsIdentity]::GetCurrent().User)>")
$report = @{
    radiator_version = 4
    user_given_name = $user_info_source.givenName.Value
    user_surname = $user_info_source.sn.Value
    email = $user_info_source.mail.Value
    upn = $user_info_source.UserPrincipalName.Value
    serial = $c_bios.SerialNumber
    # TODO: Merge Version and SKU into OperatingSystem string? Less flexible but simpler
    os_version = $c_os.Version
    os_sku = $c_os.OperatingSystemSKU
    os_arch = $c_os.OSArchitecture
    mfg = $c_system.Manufacturer
    model = $c_system.Model
    computer_name = $c_system.Name
    system_type = $c_system.PCSystemType
    ram = $c_system.TotalPhysicalMemory
    boot_drive = $c_volume.DriveLetter
    boot_drive_fs = $c_volume.FileSystem
    boot_drive_cap = $c_volume.Capacity
    boot_drive_free = $c_volume.FreeSpace
}

if ($null -ne $user_info_source.objectGUID.Value) {
    $report["user_objectGUID"] = [Guid]($user_info_source.objectGUID.Value)
} else {
    $report["user_objectGUID"] = $null
}

# This uniquely identifies the user
if ($null -ne $user_info_source.'mS-DS-ConsistencyGuid'.Value) {
    $report["user_sourceAnchor"] = [System.Convert]::ToBase64String($user_info_source.'mS-DS-ConsistencyGuid'.Value)
} else {
    $report["user_sourceAnchor"] = $null
}

# TODO: get user data for non-domain connected computers

$network_configs = @{}
ForEach ($c_net in $c_netset) {
    # Iterate over array elements and assign type stringValue
    ForEach ($t in $c_net.IPAddress) {
        [array]$ip_list += $t
    }
    ForEach ($t in $c_net.IPSubnet) {
        [array]$subnet_list += $t
    }
    ForEach ($t in $c_net.DefaultIPGateway) {
        [array]$gateway_list += $t
    }
    ForEach ($t in $c_net.DNSServerSearchOrder) {
        [array]$dns_list += $t
    }

    $network_config = @{
        dhcp_enabled = $c_net.DHCPEnabled
        dhcp_server = $c_net.DHCPServer
        dns_hostname = $c_net.DNSHostName
        ips = $ip_list
        subnets = $subnet_list
        gateways = $gateway_list
        dns_order = $dns_list
    }

    $network_configs[$c_net.MACAddress] = $network_config
}

$report["network_config"] = $network_configs 

# ContentType required to prevent interpretation as multipart form data
$request = [System.Net.WebRequest]::Create($dyle_endpoint)
$request.ContentType = "application/json"
$request.Method = "POST"

try {
    $requestStream = $request.GetRequestStream()
    $streamWriter = New-Object System.IO.StreamWriter($requestStream)

    if ($PSVersionTable.PSVersion.Major -lt 3) {
        # Old PowerShell with no ConvertTo-Json, use imported module
        # ConvertTo-STJson https://github.com/EliteLoser/ConvertTo-Json
        Import-Module .\ConvertTo-STJson.ps1
        Write-Output "PS version < 3, loading in JSON module"    
        $streamWriter.Write($(ConvertTo-STJson $report))
    } else {
        $streamWriter.Write($(ConvertTo-Json -Depth 4 $report))
    }
}

finally {
    if ($null -ne $streamWriter) { $streamWriter.Dispose() }
    if ($null -ne $requestStream) { $requestStream.Dispose() }
}

$res = $request.GetResponse()
Write-Output $res

# subsequent runs fail after successful first run, close the response
# https://stackoverflow.com/questions/5827030/httpwebrequest-times-out-on-second-call
$res.close()