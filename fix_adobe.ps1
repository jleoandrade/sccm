# 1. Terminate all running Adobe processes for all users 

Stop-Process -Name "Acrobat", "AcroRd32" -ErrorAction SilentlyContinue 

  

# 2. Automatically locate the Adobe Plug_ins folder (Handles both 64-bit and 32-bit versions) 

$AdobePath64 = "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\plug_ins" 

$AdobePath32 = "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\plug_ins" 

  

if (Test-Path $AdobePath64) { $TargetFolder = $AdobePath64 } 

elseif (Test-Path $AdobePath32) { $TargetFolder = $AdobePath32 } 

  

# 3. Disable the corrupted FileOpen.api plugin globally 

if ($TargetFolder) { 

    $PluginPath = Join-Path $TargetFolder "FileOpen.api" 

    if (Test-Path $PluginPath) { 

        # Renaming to .bak disables the plugin from loading, resolving the launch hang 

        Rename-Item -Path $PluginPath -NewName "FileOpen.api.bak" -Force 

        Write-Host "Success: FileOpen.api has been disabled globally for all users." -ForegroundColor Green 

    } else { 

        Write-Host "FileOpen.api plugin was not found in the directory, checking standard registry fix..." -ForegroundColor Yellow 

    } 

} 

  

# 4. Clean up window placement registry cache for the current user and profiles 

$RegPath = "HKCU:\Software\Adobe\Adobe Acrobat\DC\SDI" 

if (Test-Path $RegPath) { Remove-Item -Path $RegPath -Recurse -Force } 

  

# 5. Launch Adobe Acrobat to verify it now opens fully maximized 

$ExePath = "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\Acrobat.exe" 

if (-not (Test-Path $ExePath)) {  

    $ExePath = "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"  

} 

  

if (Test-Path $ExePath) { 

    Start-Process -FilePath $ExePath -WindowStyle Maximized 

    Write-Host "Adobe Acrobat launched successfully in Maximized style!" -ForegroundColor Green 

} else { 

    Write-Host "Adobe executable not found." -ForegroundColor Red 

} 

 
 