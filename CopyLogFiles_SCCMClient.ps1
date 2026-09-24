$computerName = Read-Host "Digite o nome da máquina remota"

$localDestFolder = "C:\temp\0X80D02002\logs\$computerName"
$ccmLogFolder = "\\$computerName\c$\Windows\CCM\Logs"
$detailsFile = Join-Path $localDestFolder "details.txt"

if (-not (Test-Path $localDestFolder)) {
    New-Item -ItemType Directory -Path $localDestFolder -Force | Out-Null
}

$osInfo = Get-CimInstance Win32_OperatingSystem -ComputerName $computerName
$osName = $osInfo.Caption
$osVersion = $osInfo.Version
$osBuild = $osInfo.BuildNumber

$detailsContent = @"
Device name: $computerName
Operating system version and build: $osName (Version: $osVersion, Build: $osBuild)
"@
Set-Content -Path $detailsFile -Value $detailsContent -Encoding UTF8

$logFiles = @(
    "UpdatesDeployment.log", "UpdatesHandler.log", "WUAHandler.log", 
    "ScanAgent.log", "RebootCoordinator.log", "CIAgent.log", 
    "LocationServices.log", "ClientLocation.log"
)

foreach ($log in $logFiles) {
    $sourcePath = Join-Path $ccmLogFolder $log
    $destinationPath = Join-Path $localDestFolder $log
    if (Test-Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $destinationPath -Force
    }
}

Write-Host "Concluído com sucesso!" -ForegroundColor Green
