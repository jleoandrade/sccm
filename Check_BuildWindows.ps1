# List of computers to check
$computers = @(

"1082221A"

)

# Windows 11 KBs
$KBs = @("KB5093998", "KB5094126")

foreach ($pc in $computers) {

    Write-Host "`n====================================" -ForegroundColor DarkCyan
    Write-Host "Checking machine: $pc" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor DarkCyan

    # Connectivity test
    if (-not (Test-Connection -ComputerName $pc -Count 1 -Quiet)) {
        Write-Host "$pc -> UNREACHABLE (No network response)" -ForegroundColor Yellow
        continue
    }

    try {
        # Use PowerShell Remoting to read registry values
        $cv = Invoke-Command -ComputerName $pc -ScriptBlock {
            Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        }

        $currentBuild = $cv.CurrentBuild      # Example: 22631
        $ubr         = $cv.UBR                # Example: 6783
        $fullBuild   = "$currentBuild.$ubr"   # Example: 22631.6783

        # Get OS caption
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $pc
        $osCaption = $os.Caption

        Write-Host "Operating System: $osCaption" -ForegroundColor White
        Write-Host "OS Build: $fullBuild" -ForegroundColor White
        Write-Host "Patch Level (UBR): $ubr" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Unable to retrieve OS build / patch level (Remoting may be disabled)." -ForegroundColor Yellow
    }

    # Check KB installation
    foreach ($kb in $KBs) {
        try {
            $patch = Get-HotFix -ComputerName $pc -ErrorAction Stop |
                     Where-Object { $_.HotFixID -eq $kb }

            if ($patch) {
                Write-Host "`n$pc -> PATCH INSTALLED: $kb" -ForegroundColor Green
                Write-Host "Installed On: $($patch.InstalledOn)" -ForegroundColor Green
            }
            else {
                Write-Host "`n$pc -> PATCH NOT INSTALLED: $kb" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "`n$pc -> Unable to query hotfix information." -ForegroundColor Yellow
        }
    }

    Write-Host "`nCheck completed for $pc." -ForegroundColor Cyan
}
