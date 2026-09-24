# 1. Define Target Computers and Report Output Path
$Computers = @(

    "6051855A"
    "LAB-2120993"
    "LAB-DP5570"
    "LAB-DP5680"
    "1582833A"
    "1585421A"
    "LAB-DLR7330"
    "1566852A"
)
$MasterCsvPath = "C:\temp\Mass_Uninstallation_Report.csv"

# 2. Initialize a list to store all machine records
$ReportResults = [System.Collections.Generic.List[PSCustomObject]]::new()

# 3. Process each computer in the array
foreach ($Computer in $Computers) {
    Write-Host "Processing log for computer: $Computer..." -ForegroundColor Cyan
    
    # Remote paths using C$ administrative share
    $LogPath = "\\$Computer\C$\temp\CBandSEPUnistall.log"
    
    # Initialize default statuses
    $IPAddress       = "Offline/Unknown"
    $SEP_Uninstalled = "No Log Found"
    $CB_Uninstalled  = "No Log Found"

    # Test if the computer is reachable over the network
    if (Test-Connection -ComputerName $Computer -Count 1 -Quiet) {
        
        # Get the remote IP address resolved by the network DNS
        try {
            $IPAddress = [System.Net.Dns]::GetHostAddresses($Computer) | 
                         Where-Object { $_.AddressFamily -eq 'InterNetwork' } | 
                         Select-Object -ExpandProperty IPAddressToString -First 1
        } catch {
            $IPAddress = "IP Resolution Error"
        }

        # Check if the log file exists on the remote machine
        if (Test-Path $LogPath) {
            try {
                $LogContent = Get-Content -Path $LogPath -Raw

                # Regex patterns matching your uninstallation outputs
                $SEP_Regex = "Symantec folder found\. Proceeding with uninstallation\."
                $CB_Regex  = "Carbon Black folder found\. Proceeding with uninstallation\."

                # FIXED: Replaced legacy-incompatible ternary operators with standard if/else statements
                if ($LogContent -match $SEP_Regex) { $SEP_Uninstalled = "Yes" } else { $SEP_Uninstalled = "No" }
                if ($LogContent -match $CB_Regex)  { $CB_Uninstalled  = "Yes" } else { $CB_Uninstalled  = "No" }
                
            } catch {
                $SEP_Uninstalled = "Read Error"
                $CB_Uninstalled  = "Read Error"
            }
        }
    } else {
        $IPAddress       = "Offline"
        $SEP_Uninstalled = "Host Offline"
        $CB_Uninstalled  = "Host Offline"
    }

    # FIXED: Replaced legacy-incompatible ternary operator for joint completion status
    if ($SEP_Uninstalled -eq "Yes" -and $CB_Uninstalled -eq "Yes") {
        $Both_Uninstalled = "Yes"
    } else {
        $Both_Uninstalled = "No"
    }

    # Construct the data row matching your layout
    $MachineData = [PSCustomObject]@{
        "Asset TAG"               = $Computer
        "IP"                      = $IPAddress
        "SEP Uninstalled"         = $SEP_Uninstalled
        "Carbon Black Uinstalled" = $CB_Uninstalled
        "CB and SEP Uinstalled"   = $Both_Uninstalled
    }

    $ReportResults.Add($MachineData)
}

# 4. Export all computer results into a single central CSV file
$TargetDirectory = Split-Path $MasterCsvPath
if (-not (Test-Path $TargetDirectory)) {
    New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
}

$ReportResults | Export-Csv -Path $MasterCsvPath -NoTypeInformation -Encoding UTF8 -Force

Write-Host "Mass summary report generated at: $MasterCsvPath" -ForegroundColor Green
