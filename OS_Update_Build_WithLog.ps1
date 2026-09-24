# --- Path Configuration ---
$workingDir   = "C:\Temp"
$mountDir     = "$workingDir\mnt"
$msuDir       = "$workingDir\msu"
$wimDir       = "$workingDir\wim"
$logFile      = "$workingDir\process_log.txt"

# --- 1. Prepare Environment ---
Write-Host "Checking directories..." -ForegroundColor Cyan
foreach ($path in @($mountDir, $msuDir, $wimDir)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

# Find the WIM file
$sourceWimFile = Get-ChildItem -Path $wimDir -Filter *.wim | Select-Object -First 1
if (-not $sourceWimFile) { 
    Write-Error "No WIM file found!"; return 
}

$sourceWim    = $sourceWimFile.FullName
$currentMonth = (Get-Date).ToString("MMMM")
$targetWim    = "$wimDir\install$currentMonth.wim"
$index        = 1

# Start Log
"--- Process Started: $(Get-Date) ---" | Add-Content $logFile

# --- 2. Mount Image ---
Write-Host "Mounting Image..." -ForegroundColor Cyan
dism /Mount-Image /ImageFile:$sourceWim /Index:$index /MountDir:$mountDir >> $logFile

# --- 3. Add Updates (One by One) ---
do {
    $msuFiles = Get-ChildItem -Path $msuDir -Filter *.msu
    
    if ($msuFiles.Count -eq 1) {
        Write-Host "Installing: $($msuFiles.Name)" -ForegroundColor Yellow
        dism /Image:$mountDir /Add-Package /PackagePath:$($msuFiles.FullName) >> $logFile
        
        $answer = Read-Host "Do you want to add another KB? (y/n)"
        if ($answer -eq 'y') {
            Write-Host "Please REPLACE the file in $msuDir with the NEW KB, then press ENTER." -ForegroundColor Magenta
            pause
        }
    } 
    elseif ($msuFiles.Count -gt 1) {
        Write-Host "Error: More than 1 KB file found! Please leave only ONE." -ForegroundColor Red
        $answer = 'y'
        pause
    }
    else {
        Write-Host "No KB file found in folder." -ForegroundColor Red
        $answer = 'n'
    }
} while ($answer -eq 'y')

# --- 4. Cleanup and Unmount ---
Write-Host "Cleaning up components..." -ForegroundColor Cyan
dism /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase >> $logFile

Write-Host "Unmounting and Saving..." -ForegroundColor Cyan
dism /Unmount-Image /MountDir:$mountDir /Commit >> $logFile

# --- 5. Export and Finalize ---
Write-Host "Exporting to final WIM..." -ForegroundColor Cyan
dism /Export-Image /SourceImageFile:$sourceWim /SourceIndex:$index /DestinationImageFile:$targetWim /Compress:max >> $logFile

dism /Cleanup-Wim >> $logFile
Write-Host "Success! Log saved at: $logFile" -ForegroundColor Green
