# Prompt the user for the computer name
$ComputerName = Read-Host "Enter the computer name (or press Enter for local machine)"
if (-not $ComputerName) { $ComputerName = "localhost" }

Write-Host "`nConnecting to: $ComputerName..." -ForegroundColor Cyan

# Define the target path (switches to network share format if remote)
if ($ComputerName -eq "localhost") {
    $TargetDrive = "C:\"
    $CimDrive = "C:"
} else {
    $TargetDrive = "\\$ComputerName\C$"
    $CimDrive = "C:"
}

# Verify if the path is accessible
if (-not (Test-Path $TargetDrive)) {
    Write-Host "Error: Could not access the path $TargetDrive. Check the name or your permissions." -ForegroundColor Red
    exit
}

# [FUNCTIONALITY 9] Fetch and display Total and Free Disk Space Info
try {
    $DiskInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$CimDrive'" -ComputerName $ComputerName -ErrorAction Stop
    if ($DiskInfo) {
        $TotalSizeGB = [math]::Round(($DiskInfo.Size / 1GB), 2)
        $FreeSpaceGB = [math]::Round(($DiskInfo.FreeSpace / 1GB), 2)
        $UsedSpaceGB = [math]::Round(($TotalSizeGB - $FreeSpaceGB), 2)

        Write-Host "--- DISK HEALTH OVERVIEW ($CimDrive) ---" -ForegroundColor Green
        Write-Host "Total Size: $TotalSizeGB GB"
        Write-Host "Used Space: $UsedSpaceGB GB"
        Write-Host "Free Space: $FreeSpaceGB GB" -ForegroundColor ($ifFree = if ($FreeSpaceGB -lt 20) { "Red" } else { "Green" })
        Write-Host "-------------------------------------`n"
    }
} catch {
    Write-Host "Warning: Could not retrieve overall disk capacity stats, but will proceed with folder analysis.`n" -ForegroundColor Yellow
}

Write-Host "Analyzing C: drive space consumption..." -ForegroundColor Yellow

# Get top-level directories to scan
$Folders = Get-ChildItem -Path $TargetDrive -Directory -ErrorAction SilentlyContinue
$TotalFolders = $Folders.Count
$CurrentFolderIndex = 0

# Collect and calculate the size of top-level folders
$Results = ForEach ($Folder in $Folders) {
    $CurrentFolderIndex++
    
    # [FUNCTIONALITY 2] Update the Visual Progress Bar on top of the console window
    $PercentComplete = [math]::Round(($CurrentFolderIndex / $TotalFolders) * 100)
    Write-Progress -Activity "Scanning Storage" -Status "Processing: $($Folder.Name)" -PercentComplete $PercentComplete

    # Calculate size by summing up all files inside the folder
    $SizeSum = Get-ChildItem -Path $Folder.FullName -Recurse -File -ErrorAction SilentlyContinue | 
               Measure-Object -Property Length -Sum

    # Convert size to Gigabytes (GB)
    $SizeGB = [math]::Round(($SizeSum.Sum / 1GB), 2)

    # Create a custom object with the results
    [PSCustomObject]@{
        "Folder Name" = $Folder.Name
        "Path"        = $Folder.FullName
        "Size (GB)"   = $SizeGB
    }
}

# Clear the progress bar after completion
Write-Progress -Activity "Scanning Storage" -Completed

# Output the sorted final table to screen
$Results | Sort-Object "Size (GB)" -Descending | Format-Table -AutoSize
