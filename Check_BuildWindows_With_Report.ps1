# List of computers to check
$computers = @(

"1585209A"

)

# Windows 11 KBs
$KBs = @("KB5093998", "KB5094126")

# CSV output configuration
$folderPath = "C:\temp"
if (-not (Test-Path $folderPath)) { New-Item -ItemType Directory -Path $folderPath -Force | Out-Null }
$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath    = "$folderPath\kb_installed_$timestamp.csv"

# Array to store CSV results
$report = @()

foreach ($pc in $computers) {

    Write-Host "`n====================================" -ForegroundColor DarkCyan
    Write-Host "Checking machine: $pc" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor DarkCyan

    # Initialize report variables for this machine
    $isOnline     = "No"
    $dnsError     = "No"
    $kbStatusList = @()

    # DNS and Connectivity validation
    try {
        [System.Net.Dns]::GetHostEntry($pc) | Out-Null
    }
    catch {
        $dnsError = "Yes"
        Write-Host "$pc -> DNS ERROR (Could not resolve hostname)" -ForegroundColor Red
    }

    if (-not (Test-Connection -ComputerName $pc -Count 1 -Quiet)) {
        Write-Host "$pc -> UNREACHABLE (No network response)" -ForegroundColor Yellow
    }
    else {
        $isOnline = "Yes"
    }

    # If offline or DNS error, log it and skip to next machine
    if ($isOnline -eq "No") {
        foreach ($kb in $KBs) {
            $report += [PSCustomObject]@{
                Computer       = $pc
                Online         = $isOnline
                DNSError       = $dnsError
                KB             = $kb
                KBStatus       = "Not Checked (Offline)"
                InstallationDate = "N/A"
            }
        }
        continue
    }

    # Collect Operating System details
    try {
        $cv = Invoke-Command -ComputerName $pc -ScriptBlock {
            Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        }
        $currentBuild = $cv.CurrentBuild
        $ubr         = $cv.UBR
        $fullBuild   = "$currentBuild.$ubr"

        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $pc
        $osCaption = $os.Caption

        Write-Host "Operating System: $osCaption" -ForegroundColor White
        Write-Host "OS Build: $fullBuild" -ForegroundColor White
        Write-Host "Patch Level (UBR): $ubr" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Unable to retrieve OS build / patch level (Remoting may be disabled)." -ForegroundColor Yellow
    }

    # Verify installed KBs
    foreach ($kb in $KBs) {
        $statusKB   = "Not Installed"
        $installedOn = "N/A"

        try {
            $patch = Get-HotFix -ComputerName $pc -ErrorAction Stop | Where-Object { $_.HotFixID -eq $kb }

            if ($patch) {
                Write-Host "`n$pc -> PATCH INSTALLED: $kb" -ForegroundColor Green
                Write-Host "Installed On: $($patch.InstalledOn)" -ForegroundColor Green
                $statusKB   = "Installed"
                $installedOn = $($patch.InstalledOn).ToString()
            }
            else {
                Write-Host "`n$pc -> PATCH NOT INSTALLED: $kb" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "`n$pc -> Unable to query hotfix information." -ForegroundColor Yellow
            $statusKB = "Query Error"
        }

        # Add data row to report array
        $report += [PSCustomObject]@{
            Computer         = $pc
            Online           = $isOnline
            DNSError         = $dnsError
            KB               = $kb
            KBStatus         = $statusKB
            InstallationDate = $installedOn
        }
    }

    Write-Host "`nCheck completed for $pc." -ForegroundColor Cyan
}

# Export all gathered results to CSV file
if ($report.Count -gt 0) {
    $report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n[SUCCESS] Report generated at: $csvPath" -ForegroundColor Green
}
