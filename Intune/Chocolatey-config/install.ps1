choco source add -n=onprem -s=http://nexus.main.tbte.ca:8081/repository/chocolatey-group/
choco source remove -n=chocolatey
choco source add -n=chocolatey -s=https://community.chocolatey.org/api/v2/ —priority=1