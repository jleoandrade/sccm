# Path where the CSV file will be saved
$csvPath = "C:\temp\Patch_Check_Results.csv"

# List of computers to check
$computers = @(
"1584684A"
"1583220A"
"1584101A"
"1585735A"
"1585980A"
"1586207A"
"1585988A"
"1583333A"
"1589552A"
"1588292A"
"1584687A"
)

# Windows 11 KBs
$KBs = @("KB5087420", "KB5089549")

# Array to store the CSV results
$report = @()

foreach ($pc in $computers) {

    Write-Host "`n====================================" -ForegroundColor DarkCyan
    Write-Host "Checking machine: $pc" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor DarkCyan

    # Initialize variables for the current computer report
    $fullBuild = "N/A"
    $checkedCompleted = "Yes"

    # Connectivity test
    if (-not (Test-Connection -ComputerName $pc -Count 1 -Quiet)) {
        Write-Host "$pc -> UNREACHABLE (No network response)" -ForegroundColor Yellow
        
        # Add offline status to the report for each configured KB
        foreach ($kb in $KBs) {
            $report += [PSCustomObject]@{
                "Asset TAG"         = $pc
                "OS Build"          = "Unreachable"
                "Patch Installed"   = "No (Offline)"
                "Installed On"      = "N/A"
                "Checked Completed" = "No (Connection Error)"
            }
        }
        continue
    }

    try {
        # Use PowerShell Remoting to read registry values
        $cv = Invoke-Command -ComputerName $pc -ScriptBlock {
            Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        } -ErrorAction Stop

        $currentBuild = $cv.CurrentBuild      # Example: 22631
        $ubr         = $cv.UBR                # Example: 6783
        $fullBuild   = "$currentBuild.$ubr"   # Example: 22631.6783

        # Get OS caption
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $pc -ErrorAction Stop
        $osCaption = $os.Caption

        Write-Host "Operating System: $osCaption" -ForegroundColor White
        Write-Host "OS Build: $fullBuild" -ForegroundColor White
        Write-Host "Patch Level (UBR): $ubr" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Unable to retrieve OS build / patch level (Remoting may be disabled)." -ForegroundColor Yellow
        $fullBuild = "Access Error (WinRM)"
        $checkedCompleted = "Partial (Read Error)"
    }

    # Check KB installation
    foreach ($kb in $KBs) {
        $patchStatus = "Not Installed"
        $installedOn = "N/A"

        try {
            $patch = Get-HotFix -ComputerName $pc -ErrorAction Stop |
                     Where-Object { $_.HotFixID -eq $kb }

            if ($patch) {
                Write-Host "`n$pc -> PATCH INSTALLED: $kb" -ForegroundColor Green
                Write-Host "Installed On: $($patch.InstalledOn)" -ForegroundColor Green
                $patchStatus = "Installed"
                $installedOn = $($patch.InstalledOn)
            }
            else {
                Write-Host "`n$pc -> PATCH NOT INSTALLED: $kb" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "`n$pc -> Unable to query hotfix information." -ForegroundColor Yellow
            $patchStatus = "Query Error"
            $checkedCompleted = "Partial (KB Error)"
        }

        # Add data row to the report array
        $report += [PSCustomObject]@{
            "Asset TAG"         = $pc
            "OS Build"          = $fullBuild
            "Patch Installed"   = "$kb ($patchStatus)"
            "Installed On"      = $installedOn
            "Checked Completed" = $checkedCompleted
        }
    }

    Write-Host "`nCheck completed for $pc." -ForegroundColor Cyan
}

# Export all gathered data to the CSV file
if ($report.Count -gt 0) {
    # Ensure the destination directory exists
    $targetDir = Split-Path $csvPath
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

    $report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ","
    Write-Host "`n[SUCCESS] Report generated at: $csvPath" -ForegroundColor Green
}
