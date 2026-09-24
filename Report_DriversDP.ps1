# List of target servers
$servers = @(
    "CLAWSSMSP001V",
    "NJAUDBAPSP001",
    "NJBELLSMSP001",
    "NJBLGGAPSP001",
    "NJBWSMSP001",
    "NJCAMDSMSP001",
    "NJCENTSMSP001",
    "NJCLIFAPSP001",
    "NJCORBSMSP001",
    "NJCPPCSMSP001",
    "NJCRANAPSP001",
    "NJEDISAPP0026V",
    "NJEDISAPSP047",
    "NJEDISSMSP001V",
    "NJELIZAPSP001",
    "NJFLMTAPSP001",
    "NJHACKAPSP001",
    "NJHARMAPSP001",
    "NJHARRAPSP001",
    "NJHSDSMSP001",
    "NJIRVGSMSP001",
    "NJJCAPSP001",
    "NJMTROSMSP001",
    "NJNBUMGP0001V",
    "NJNBUSMSP001V",
    "NJNWKAPP0088V",
    "NJNWKMGTP147V",
    "NJNWKSMS08V",
    "NJNWKSMSP001",
    "NJNWKSMSP002",
    "NJNWKSMSP003V",
    "NJOAKSMS01",
    "NJORASMSP001",
    "NJORNGAPSP001",
    "NJPALSSMSP001",
    "NJPLFDAPSP001",
    "NJSAYGSMSP001",
    "NJSIACAPSP001",
    "NJSPLNSMSP001",
    "NJSPRGSMSP001",
    "NJSUMTAPSP001",
    "NJTRNESMSP001",
    "NJTRNGAPSP001"
)

# Output CSV configuration
$outputPath = "C:\Temp\server_disks_organized.csv"
$report = @()

Write-Host "Starting organized disk data collection..." -ForegroundColor Cyan

foreach ($server in $servers) {
    Write-Host "Connecting to: $server..." -ForegroundColor Yellow
    
    try {
        # Query only Local Fixed Disks (DriveType = 3)
        $disks = Get-CimInstance -ComputerName $server -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        
        if ($disks) {
            # Extract drive letters and sort them alphabetically (C:, D:, E:)
            $driveLetters = ($disks.DeviceID | Sort-Object) -join " "

            # Create one clean object per server
            $serverInfo = [PSCustomObject]@{
                "Server"       = $server
                "DriveLetters" = $driveLetters
                "Status"       = "Online"
            }
            $report += $serverInfo
        }
    }
    catch {
        Write-Host "Failed to connect to $server. Skipping..." -ForegroundColor Red
    }
}

# Export to a structured CSV using Semicolon (;) for perfect Excel formatting
if ($report.Count -gt 0) {
    $outputFolder = Split-Path $outputPath
    if (!(Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $report | Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
    Write-Host "`nProcess completed successfully!" -ForegroundColor Green
    Write-Host "Organized report saved to: $outputPath" -ForegroundColor Green
} else {
    Write-Host "`nNo data was collected." -ForegroundColor Red
}
