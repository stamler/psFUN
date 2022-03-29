#Note: ADDFEATURE is used to state which features to use because by default all
#features are used and they include the desktop icon. Detect install success
#with presence of C:\Program Files\PDFsam Basic\pdfsam.exe
msiexec.exe /i "pdfsam-4.2.12.msi" /quiet /norestart CHECK_FOR_NEWS=false DONATE_NOTIFICATION=false SKIPTHANKSPAGE=Yes ADDLOCAL=MainAppFeature,AddContextMenu
