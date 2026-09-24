# ============================================================
# FORCE CLEAN DEEP PRINTER, DRIVER, AND PORT REMOVAL SCRIPT
# ============================================================

$computer = Read-Host "Enter the remote computer name"
Write-Host "`nConnecting to ${computer}..." -ForegroundColor Cyan

# 1. LIST AVAILABLE VENDORS
Write-Host "`n Select the Printer Vendor (Brand):" -ForegroundColor Yellow
$vendors = @("HP", "EPSON", "Canon", "Brother", "Samsung", "Xerox", "Lexmark", "Ricoh", "Any Brand (List All)")

for ($i = 0; $i -lt $vendors.Count; $i++) {
    Write-Host "[$($i + 1)] $($vendors[$i])" -ForegroundColor White
}

do {
    $vendorChoice = Read-Host "`nEnter the number corresponding to the Vendor"
} while ($vendorChoice -match "[^\d]" -or $vendorChoice -lt 1 -or $vendorChoice -gt $vendors.Count)

$selectedVendor = $vendors[$vendorChoice - 1]
$regexFilter = if ($selectedVendor -eq "Any Brand (List All)") { "." } else { $selectedVendor }

# 2. RETRIEVING DATA REMOTELY
Write-Host "`nFetching printers and hardware mappings..." -ForegroundColor Cyan

try {
    $remoteData = Invoke-Command -ComputerName $computer -ScriptBlock {
        param($filter)
        # Verify and start Spooler if stopped
        $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
        if ($spooler -and $spooler.Status -ne 'Running') {
            Start-Service -Name Spooler -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        $printers = Get-Printer | Where-Object { $_.Name -match $filter -or $_.DriverName -match $filter }
        
        # We target the printer names directly to map hardware instances safely via PnPUtil
        return [PSCustomObject]@{
            Printers = $printers
        }
    } -ArgumentList $regexFilter -ErrorAction Stop
} catch {
    Write-Host "Error connecting or retrieving data from ${computer}: $_" -ForegroundColor Red
    Exit
}

$foundPrinters = $remoteData.Printers

# 3. INTERACTIVE PRINTER SELECTION FOR REMOVAL
if (-not $foundPrinters) {
    Write-Host "`nNo printers found for the vendor filter '$selectedVendor'." -ForegroundColor Red
} else {
    Write-Host "`n Select the Printer you want to COMPLETELY REMOVE:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $foundPrinters.Count; $i++) {
        Write-Host "[$($i + 1)] Name: $($foundPrinters[$i].Name) | Driver: $($foundPrinters[$i].DriverName)" -ForegroundColor White
    }
    
    do {
        $printerChoice = Read-Host "`nEnter the number corresponding to the printer"
    } while ($printerChoice -match "[^\d]" -or $printerChoice -lt 1 -or $printerChoice -gt $foundPrinters.Count)

    $targetPrinter = $foundPrinters[$printerChoice - 1]
    $confirm = Read-Host "`nAre you sure you want to completely delete '$($targetPrinter.Name)', its drivers, and ports? (Y/N)"
    
    if ($confirm -match "^[Yy]$") {
        Write-Host "`nStarting deep removal process..." -ForegroundColor Magenta

        Invoke-Command -ComputerName $computer -ScriptBlock {
            param($printerName, $driverName, $portName)
            
            # A. Purge Stuck Print Jobs & Kill Locks
            Write-Host "Purging any active print jobs for: $printerName..."
            Get-PrintJob -PrinterName $printerName -ErrorAction SilentlyContinue | Remove-PrintJob -ErrorAction SilentlyContinue
            
            # B. Remove Print Queue
            Write-Host "Removing print queue..."
            Remove-Printer -Name $printerName -ErrorAction SilentlyContinue

            # C. Force Remove Device Associations via Global PnPUtility Native String Match
            Write-Host "Searching and uninstalling related PnP devices using PnPUtil..."
            $cleanName = $printerName -replace '\s*\(.*?\)\s*', ''
            
            # Native cmd fallback: Finds devices matching the name string to strip out phantom drivers
            $devices = pnputil /enum-devices /string $cleanName /format table 2>$null | Where-Object { $_ -match "Instance ID:" }
            foreach ($line in $devices) {
                if ($line -match 'Instance ID:\s+(?<id>\S+)') {
                    $devId = $Matches['id']
                    Write-Host "Removing hardware instance: $devId..."
                    pnputil /remove-device $devId /force | Out-Null
                }
            }

            # D. Remove Driver
            $otherPrintersUsingDriver = Get-Printer | Where-Object { $_.DriverName -eq $driverName }
            if (-not $otherPrintersUsingDriver) {
                Write-Host "Removing unused driver: $driverName..."
                Remove-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue
            } else {
                Write-Host "Driver '$driverName' is still in use by another printer instance." -ForegroundColor DarkYellow
            }

            # E. Remove Port
            if ($portName -notmatch "LPT" -and $portName -notmatch "COM" -and $portName -notmatch "USB") {
                $otherPrintersUsingPort = Get-Printer | Where-Object { $_.PortName -eq $portName }
                if (-not $otherPrintersUsingPort) {
                    Write-Host "Removing port: $portName..."
                    Remove-PrinterPort -Name $portName -ErrorAction SilentlyContinue
                }
            }

            # F. Final Refresh: Cycle Spooler to update Control Panel UI
            Write-Host "Cycling the Spooler service to finalize..."
            Restart-Service -Name Spooler -Force -ErrorAction SilentlyContinue

        } -ArgumentList $targetPrinter.Name, $targetPrinter.DriverName, $targetPrinter.PortName

        Write-Host "`nPrinter '$($targetPrinter.Name)' and its components have been successfully processed." -ForegroundColor Green
    } else {
        Write-Host "`nAction canceled by user." -ForegroundColor Yellow
    }
}

Write-Host "`nProcess completed." -ForegroundColor Green
