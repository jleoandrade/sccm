# --- Configuration ---
$remoteComputer = "1589268A"
$baseLocalPath  = "D:\KB"        # Source: where folders 23h2, 24h2, 25h2 are
$remoteTempPath = "C:\Temp\msu"  # Destination: where files go on the remote PC

# --- 1. Identify Remote Windows Version ---
Write-Host "Connecting to $remoteComputer to check Windows version..." -ForegroundColor Cyan
try {
    $winVersion = Invoke-Command -ComputerName $remoteComputer -ScriptBlock {
        (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
    }
} catch {
    Write-Error "Could not connect to $remoteComputer"; return
}

Write-Host "Detected Remote Version: $winVersion" -ForegroundColor Magenta

# --- 2. Match and Copy Folder ---
$sourceFolder = Join-Path $baseLocalPath $winVersion

if (Test-Path $sourceFolder) {
    Write-Host "Found matching folder: $sourceFolder" -ForegroundColor Green
    
    # Ensure remote directory exists
    Invoke-Command -ComputerName $remoteComputer -ScriptBlock {
        if (!(Test-Path "C:\Temp\msu")) { New-Item -Path "C:\Temp\msu" -ItemType Directory -Force }
    }

    Write-Host "Copying updates to remote machine..." -ForegroundColor Cyan
    Copy-Item -Path "$sourceFolder\*.msu" -Destination "\\$remoteComputer\C$\Temp\msu\" -Force
} else {
    Write-Error "No update folder found for version $winVersion at $baseLocalPath"
    return
}

# --- 3. Execute DISM Remotely ---
Invoke-Command -ComputerName $remoteComputer -ScriptBlock {
    $msuDir = "C:\Temp\msu"
    $msuFiles = Get-ChildItem -Path $msuDir -Filter *.msu
    
    Write-Host "`n--- Starting Installation ---" -ForegroundColor Cyan
    foreach ($file in $msuFiles) {
        Write-Host "Installing: $($file.Name)... " -ForegroundColor Yellow -NoNewline
        $process = Start-Process dism.exe -ArgumentList "/Online /Add-Package /PackagePath:$($file.FullName) /NoRestart" -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "DONE" -ForegroundColor Green
        } else {
            Write-Host "FAILED (Code: $($process.ExitCode))" -ForegroundColor Red
        }
    }
    Write-Host "--- Process Finished ---`n" -ForegroundColor Cyan
}
