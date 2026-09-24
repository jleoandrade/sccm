# --- Path Configuration ---
$workingDir   = "C:\Temp"
$mountDir     = "$workingDir\mnt"
$msuDir       = "$workingDir\msu"
$wimDir       = "$workingDir\wim"

# Dynamically find the existing WIM file in the directory
$sourceWimFile = Get-ChildItem -Path $wimDir -Filter *.wim | Select-Object -First 1
if (-not $sourceWimFile) {
    Write-Error "No .wim file found in $wimDir. Please check the folder."
    return
}
$sourceWim = $sourceWimFile.FullName

# Dynamic naming based on current month (e.g., installAugust.wim)
$currentMonth = (Get-Date).ToString("MMMM", [System.Globalization.CultureInfo]::InvariantCulture)
$targetWim    = "$wimDir\install$currentMonth.wim"

$index = 1 

# --- 1. Prepare Environment ---
Write-Host "Checking directories..." -ForegroundColor Cyan
foreach ($path in @($mountDir, $msuDir, $wimDir)) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

# --- 2. Mount the WIM ---
Write-Host "Mounting: $($sourceWimFile.Name)" -ForegroundColor Cyan
dism /Mount-Image /ImageFile:$sourceWim /Index:$index /MountDir:$mountDir

# --- 3. Add MSU Updates ---
Write-Host "Integrating updates from $msuDir..." -ForegroundColor Cyan
dism /Image:$mountDir /Add-Package /PackagePath:$msuDir

# --- 4. Component Cleanup (Crucial for size reduction) ---
Write-Host "Cleaning up old components (ResetBase)..." -ForegroundColor Cyan
dism /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase

# --- 5. Unmount and Commit ---
Write-Host "Unmounting and saving changes..." -ForegroundColor Cyan
dism /Unmount-Image /MountDir:$mountDir /Commit

# --- 6. Export (Final size reduction) ---
Write-Host "Exporting to: $targetWim with maximum compression..." -ForegroundColor Cyan
dism /Export-Image /SourceImageFile:$sourceWim /SourceIndex:$index /DestinationImageFile:$targetWim /Compress:max

# --- 7. Final DISM Cleanup ---
dism /Cleanup-Wim

Write-Host "Success! The $currentMonth file has been generated at: $targetWim" -ForegroundColor Green
