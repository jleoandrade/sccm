# 1. Prompt the user for the target machine name or IP
$targetMachine = Read-Host "Enter the target machine name or IP address"

# Validate that the input is not empty
if ([string]::IsNullOrWhiteSpace($targetMachine)) {
    Write-Error "Target machine cannot be blank. Script aborted."
    exit
}

# Variable definitions with dynamic target
$source          = "\\claue1fsp0002\SoftwarePackages-CurrentBranch\SEP\SEPUninst\2026\Uninstall_SEP.ps1"
# FIXED: Changed from \temp\ to \C$\temp\ to use the administrative share
$destination     = "\\$targetMachine\C$\temp\sep_uninstall\"
$targetLocalPath = "C:\temp\sep_uninstall\Uninstall_SEP.ps1"

# 2. Enable and repair WinRM locally to avoid connection issues
Write-Host "[...] Checking and enabling WinRM Service locally..." -ForegroundColor Cyan
try {
    Enable-PSRemoting -Force -ErrorAction Stop
    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM -ErrorAction SilentlyContinue
    Write-Host "[OK] WinRM is enabled and running locally." -ForegroundColor Green
} catch {
    Write-Warning "Could not force Enable-PSRemoting locally. Proceeding anyway: $_"
}

# 3. Validate if the source file exists
if (Test-Path $source) {
    Write-Host "[OK] Source file found." -ForegroundColor Green
    
    # 4. Create the destination folder if it does not exist
    if (-not (Test-Path $destination)) {
        try {
            # Added -ErrorAction Stop to prevent the script from continuing if folder creation fails
            New-Item -ItemType Directory -Force -Path $destination -ErrorAction Stop | Out-Null
            Write-Host "[OK] Destination folder created." -ForegroundColor Green
        } catch {
            Write-Error "Failed to create destination folder. Verify network path, administrative shares (C$), or permissions: $_"
            exit
        }
    } else {
        Write-Host "[OK] Destination folder already exists." -ForegroundColor Green
    }
    
    # 5. Copy the uninstallation script
    Write-Host "[...] Copying Uninstall_SEP.ps1 to $targetMachine..." -ForegroundColor Cyan
    try {
        Copy-Item -Path $source -Destination $destination -Force -ErrorAction Stop
        Write-Host "[OK] File copied successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to copy file to destination: $_"
        exit
    }
    
    # 6. Execute the script remotely on the target machine
    Write-Host "[...] Initiating remote execution on $targetMachine..." -ForegroundColor Cyan
    try {
        Invoke-Command -ComputerName $targetMachine -ScriptBlock {
            param($path)
            
            # Forces WinRM health inside the target machine before running the file
            Enable-PSRemoting -Force | Out-Null
            
            if (Test-Path $path) {
                Write-Host "[Remote] Executing the uninstallation script..." -ForegroundColor Yellow
                & $path
            } else {
                Write-Error "[Remote] Error: File not found locally at $path"
            }
        } -ArgumentList $targetLocalPath
        
        Write-Host "[OK] Remote execution process completed." -ForegroundColor Green
    } catch {
        Write-Error "Failed to execute remote command on ${targetMachine}: $_"
    }

} else {
    Write-Error "Error: Source file not found at: $source"
}
