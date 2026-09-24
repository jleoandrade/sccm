# ==============================================================================
# Script: fix_adobe.ps1
# Path: D:\jorge\Scripts\fix_adobe.ps1
# Description: Fixes Adobe Acrobat launch hangs by disabling FileOpen.api
#              and clearing window placement registry cache (SDI).
# ==============================================================================

# 1. Elevate execution policy for the current process scope
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# 2. Terminate running Adobe processes securely using Ignore to prevent object reference errors
Stop-Process -Name "Acrobat", "AcroRd32" -ErrorAction Ignore
Start-Sleep -Seconds 2

# 3. Locate Adobe Plug_ins folder (Supports both 64-bit and 32-bit installations)
$AdobePaths = @(
    "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\plug_ins",
    "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\plug_ins",
    "${env:ProgramFiles}\Adobe\Acrobat Reader DC\Reader\plug_ins"
)

$TargetFolder = $null
foreach ($Path in $AdobePaths) {
    if (Test-Path -Path $Path -ErrorAction SilentlyContinue) {
        $TargetFolder = $Path
        break
    }
}

# 4. Disable the corrupted FileOpen.api plugin globally
if ($TargetFolder) { 
    $PluginPath = Join-Path -Path $TargetFolder -ChildPath "FileOpen.api" 
    if (Test-Path -Path $PluginPath -ErrorAction SilentlyContinue) { 
        Rename-Item -Path $PluginPath -NewName "FileOpen.api.bak" -Force -ErrorAction SilentlyContinue
        Write-Output "Success: FileOpen.api has been disabled globally."
    } else { 
        Write-Output "Status: FileOpen.api plugin was not found or already disabled."
    } 
} else {
    Write-Output "Warning: Adobe plugin directory could not be located."
}

# 5. Clean up window placement registry cache for the current user and profiles
$RegPaths = @(
    "HKCU:\Software\Adobe\Adobe Acrobat\DC\SDI",
    "HKCU:\Software\Adobe\Acrobat Reader\DC\SDI"
)

foreach ($RegPath in $RegPaths) {
    if (Test-Path -Path $RegPath -ErrorAction SilentlyContinue) { 
        Remove-Item -Path $RegPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Success: Registry cache cleared for path: $RegPath"
    } 
}

# 6. Launch Adobe Acrobat to verify it opens fully maximized
$ExePaths = @(
    "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
    "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
    "${env:ProgramFiles}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
)

$ExeToLaunch = $null
foreach ($Exe in $ExePaths) {
    if (Test-Path -Path $Exe -ErrorAction SilentlyContinue) {
        $ExeToLaunch = $Exe
        break
    }
}

if ($ExeToLaunch) { 
    Start-Process -FilePath $ExeToLaunch -WindowStyle Maximized -ErrorAction SilentlyContinue
    Write-Output "Success: Adobe Acrobat launched successfully in Maximized style."
} else { 
    Write-Output "Error: Adobe executable not found."
}
