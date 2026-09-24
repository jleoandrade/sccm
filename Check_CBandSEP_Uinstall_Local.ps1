# 1. Define File Paths
$LogPath = "C:\temp\CBandSEPUnistall.log"
$CsvPath = "C:\temp\Uninstallation_Report.csv"

# 2. Gather System Information
$AssetTag = $env:COMPUTERNAME
$IPAddress = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.254*" } | Select-Object -First 1).IPAddress

# 3. Read Log File Content (if it exists)
if (Test-Path $LogPath) {
    $LogContent = Get-Content -Path $LogPath -Raw

    # Regex patterns looking for the success paths written by your uninstallation script
    $SEP_Regex = "Symantec folder found\. Proceeding with uninstallation\."
    $CB_Regex  = "Carbon Black folder found\. Proceeding with uninstallation\."

    # Evaluate statuses using the regex matches
    $SEP_Uninstalled = $LogContent -match $SEP_Regex ? "Yes" : "No"
    $CB_Uninstalled  = $LogContent -match $CB_Regex  ? "Yes" : "No"
} else {
    # Default values if log file was missing entirely
    $SEP_Uninstalled = "Log Missing"
    $CB_Uninstalled  = "Log Missing"
}

# Evaluate joint completion status
$Both_Uninstalled = ($SEP_Uninstalled -eq "Yes" -and $CB_Uninstalled -eq "Yes") ? "Yes" : "No"

# 4. Construct the Data Object matching your exact columns
$ReportObject = [PSCustomObject]@{
    "Asset TAG"               = $AssetTag
    "IP"                      = $IPAddress
    "SEP Uninstalled"         = $SEP_Uninstalled
    "Carbon Black Uinstalled" = $CB_Uninstalled
    "CB and SEP Uinstalled"   = $Both_Uninstalled
}

# 5. Export results cleanly to CSV file
$ReportObject | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Force

Write-Host "CSV Summary Report generated successfully at: $CsvPath" -ForegroundColor Green
