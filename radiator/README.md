# radiator

Radiator sends information about computers and their users in a Windows domain environment to a REST endpoint every time it is run. It's output format is JSON. The maintained file is radiator.ps1 and it has a single remote dependency which provides ConvertTo-JSON functionality on versions of PowerShell prior to v3.0.

## install

Copy radiator.ps1 and ConvertTo-STJson.ps1 to the same directory.

## run

run radiator.ps1
