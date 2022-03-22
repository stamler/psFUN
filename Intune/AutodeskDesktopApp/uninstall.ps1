#https://knowledge.autodesk.com/support/desktop-app/troubleshooting/caas/sfdcarticles/sfdcarticles/How-to-Silently-Uninstall-Application-Manager-using-SCCM.html
taskkill /F /IM "AdAppMgr.exe"
taskkill /F /IM "Autodeskdesktopapp.exe"
net stop AdAppMgrSVC
Remove-Item $Env:ProgramData\Autodesk\SDS -Recurse
& "C:\Program Files (x86)\Autodesk\Autodesk Desktop App\removeAdAppMgr.exe" --mode unattended