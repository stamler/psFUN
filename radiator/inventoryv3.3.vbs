'RECORD INFO ON USER LOGIN

'TODO
'https://msdn.microsoft.com/en-us/library/aa394217(v=vs.85).aspx


'FUNCTIONS THAT WILL BE USED IN THE REST OF THE SCRIPT
Function stdDateFormat(theDate)
    y = Year(theDate)
    m = zeroPad(Month(theDate))
    d = zeroPad(Day(theDate))
    h = zeroPad(Hour(theDate))
    i = zeroPad(Minute(theDate))
    s = zeroPad(Second(theDate))
    stdDateFormat= y & "-" & m & "-" & d & " " & h & ":" & i & ":" & s
End Function
Function zeroPad(num)
    If(Len(num)=1) Then
        zeroPad="0"&num
    Else
        zeroPad=num
    End If
End Function
Function GetPythonListString_FromArrayOfStrings( ArrayString, Separator, quoted)
    If IsNull ( ArrayString ) Then
        StrMultiArray = chr(34) & chr(34)
    else
        StrMultiArray = "["
        length = ubound(ArrayString)
        index = 0
        For each str in ArrayString
            If(quoted = True) Then
                StrMultiArray = StrMultiArray & """" & str & """"
            else
                StrMultiArray = StrMultiArray & str
            end if
            index = index + 1
            If(index <= length) Then
                StrMultiArray = StrMultiArray & ","
            End If
        Next
        StrMultiArray = StrMultiArray + "]"
        'StrMultiArray = Join( ArrayString, Separator )
   end if
   GetPythonListString_FromArrayOfStrings = StrMultiArray
End Function
'END OF FUNCTION DEFINITIONS



set objNet = WScript.CreateObject("WScript.Network")
set objWMIService = GetObject("winMgmts:{impersonationLevel=impersonate}!root/cimv2")

'DECLARE THE VARIABLES TO LOG
Dim mfgName
Dim serialNumber
Dim totalRAM
Dim osVersion
Dim osSKU
Dim osArchitecture
Dim hddSize
Dim networkConfig

'GET SERIAL/MFG
set colItems = objWMIservice.ExecQuery("Select * from Win32_BIOS",,48)
For each objItem in colItems
	serialNumber = objItem.SerialNumber
	mfgName = objItem.Manufacturer
Next

'GET NETWORK INFO AND BUILD networkConfig VARIABLE AS JSON
'ASSUME NO MORE THAN 5 ADAPTERS (n+1 is the size apparently!?)
ReDim networkConfigArray(4)
i = 0
Set colItems = objWMIService.ExecQuery("Select * From Win32_NetworkAdapterConfiguration Where IPEnabled = True")
For each objItem in colItems

	ipaddresses = GetPythonListString_FromArrayOfStrings(objItem.IPAddress, ",", True)
  ipsubnets = GetPythonListString_FromArrayOfStrings(objItem.IPSubnet, ",", True)
  dnsserversearchorder = GetPythonListString_FromArrayOfStrings(objItem.DNSServerSearchOrder, ",", True)

  thisNetworkConfig =  "{""macaddress"":""" & objItem.MACAddress & """," & _
                         """dhcpenabled"":""" & objItem.DHCPEnabled & """," & _
                         """dhcpserver"":""" & objItem.DHCPServer & """," & _
                         """dnshostname"":""" & objItem.DNSHostName & """," & _
                         """ipaddresses"":" & ipaddresses & "," & _
                         """ipsubnets"":" & ipsubnets & "," & _
                         """dnsserversearchorder"":" & dnsserversearchorder & "}"

  networkConfigArray(i) = thisNetworkConfig
  i = i + 1
Next
ReDim Preserve networkConfigArray(i-1)
networkConfig = GetPythonListString_FromArrayOfStrings(networkConfigArray,",", False)

'GET RAM AND HARDWARE PROPS
Set colItems = objWMIService.ExecQuery("Select * from Win32_ComputerSystem")
For each objItem in colItems
  totalRAM = objItem.TotalPhysicalMemory
Next

'GET OS Details
Set colItems = objWMIService.ExecQuery("Select * from Win32_OperatingSystem")
For each objItem in colItems
  osVersion = objItem.version
  osSKU = objItem.OperatingSystemSKU
  osArchitecture = objItem.OSArchitecture
Next

'GET Hard Drive Size
Set colItems = objWMIService.ExecQuery("Select * from Win32_DiskDrive where Name like '%PHYSICALDRIVE0%'")
For each objItem in colItems
  hddSize = objItem.Size
Next




'WRITE TO FILE
'Datetime,UserName,Manufacturer,Serial,ComputerName,macAddress
set objFSO = CreateObject("Scripting.FileSystemObject")
set objFile = objFSO.OpenTextFile("\\file03.main.tbte.ca\logs\v3.3\" & objNet.ComputerName & ".log",8,True)
objFile.WriteLine("""" & stdDateFormat(Now) & """" &  "," & _
                  """" & objNet.UserName & """" & "," & _
                  """" & mfgName & """" & "," & _
                  """" & serialNumber & """" & "," & _
                  """" & objNet.ComputerName & """" & "," & _
                  """" & networkConfig & """" & "," & _
                  """" & totalRAM & """" & "," & _
                  """" & osVersion & """" & "," & _
                  """" & osSKU & """" & "," & _
                  """" & osArchitecture & """" & "," & _
                  """" & hddSize & """")
objFile.Close


'BONUS ROUND — POPULATE AD DESCRIPTION FIELD
'http://4sysops.com/archives/automatically-fill-the-computer-description-field-in-active-directory/
' get computer object in AD
Set objSysInfo = CreateObject("ADSystemInfo")
Set objComputer = GetObject("LDAP://" & objSysInfo.ComputerName)

' build up description field data and save into computer object
objComputer.Description = objNet.UserName & " (" & serialNumber & " - " & mfgName & " " & macAddress & ")"
objComputer.SetInfo
