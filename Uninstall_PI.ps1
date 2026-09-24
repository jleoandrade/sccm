# 1. Ask for the computer name
$computerName = Read-Host "Enter the computer name (or press Enter for the local machine)"
if ([string]::IsNullOrWhitespace($computerName)) { $computerName = "localhost" }

Write-Host "Connecting to $computerName and searching for PI software..." -ForegroundColor Cyan

# 2. Locate software containing "PI" in the name (32 and 64-bit registries)
$registryPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

if ($computerName -ne "localhost" -and $computerName -ne "127.0.0.1") {
    # Remote search if it's not the local machine
    $apps = Invoke-Command -ComputerName $computerName -ScriptBlock {
        Get-ItemProperty @($using:registryPaths) | 
        Where-Object { $_.DisplayName -like "*PI*" } | 
        Select-Object DisplayName, UninstallString
    } -ErrorAction SilentlyContinue
} else {
    # Local search
    $apps = Get-ItemProperty $registryPaths | 
            Where-Object { $_.DisplayName -like "*PI*" } | 
            Select-Object DisplayName, UninstallString
}

# 3. Check if any software was found
if ($null -eq $apps -or $apps.Count -eq 0) {
    Write-Host "No software with 'PI' in the name was found on $computerName." -ForegroundColor Yellow
    Exit
}

# 4. List the discovered software and ask for confirmation
Write-Host "`nSoftware found:" -ForegroundColor Yellow
$apps | ForEach-Object { Write-Host "- $($_.DisplayName)" }

$confirm = Read-Host "`nDo you really want to uninstall ALL programs listed above? (Y/N)"
if ($confirm -notmatch "^[yY]$") {
    Write-Host "Operation cancelled by user." -ForegroundColor Red
    Exit
}

# 5. Execute the uninstallation process
foreach ($app in $apps) {
    if ($app.UninstallString) {
        Write-Host "Uninstalling: $($app.DisplayName)..." -ForegroundColor Cyan
        
        # Convert uninstall string to an executable command
        # Note: Some installers require silent arguments (e.g., /quiet, /silent, /qn)
        if ($app.UninstallString -match "msiexec") {
            # If it's an MSI, force silent mode and prevent automatic reboot
            $uninstArgs = $app.UninstallString -replace "msiexec.exe", "" -replace "/I", "/X"
            $uninstArgs = "$uninstArgs /qn /norestart".Trim()
            
            if ($computerName -ne "localhost") {
                Invoke-Command -ComputerName $computerName -ScriptBlock { Start-Process msiexec.exe -ArgumentList $using:uninstArgs -Wait -NoNewWindow }
            } else {
                Start-Process msiexec.exe -ArgumentList $uninstArgs -Wait -NoNewWindow
            }
        } else {
            # If it's a regular EXE installer
            if ($computerName -ne "localhost") {
                Invoke-Command -ComputerName $computerName -ScriptBlock { Invoke-Expression $using:app.UninstallString }
            } else {
                Invoke-Expression $app.UninstallString
            }
        }
    }
}

Write-Host "Process completed!" -ForegroundColor Green
