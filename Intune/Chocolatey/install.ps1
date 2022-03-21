# Install Chocolatey to computers using Microsoft Intune
#https://www.thelazyadministrator.com/2020/02/05/intune-chocolatey-a-match-made-in-heaven/#1_-_Deploy_Chocolatey_with_Intune
Set-ExecutionPolicy Bypass -Scope Process -Force;
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072;
iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'));