$computer = Read-Host "Enter the remote computer name"

Invoke-Command -ComputerName $computer -ScriptBlock {

    $url  = "https://update.code.visualstudio.com/latest/win32-x64/stable"
    $temp = "C:\Temp"
    $installer = "C:\Temp\VSCodeSetup.exe"
    $logFile = "C:\Temp\VSCodeInstall.log"

    # Força TLS 1.2 (ambientes corporativos exigem)
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    } catch {}

    # Garante C:\Temp
    if (-not (Test-Path $temp)) {
        New-Item -Path "C:\" -Name "Temp" -ItemType Directory | Out-Null
    }

    # Limpa log anterior
    if (Test-Path $logFile) { Remove-Item $logFile -Force }

    Add-Content $logFile "=== VS Code Installation Log ==="
    Add-Content $logFile "Start: $(Get-Date)"

    Write-Host "`nDownloading Visual Studio Code..." -ForegroundColor Cyan

    # -------------------------------
    # DOWNLOAD COM PROGRESSO ASCII
    # -------------------------------
    $request  = [System.Net.WebRequest]::Create($url)
    $response = $request.GetResponse()
    $total    = $response.ContentLength
    $stream   = $response.GetResponseStream()
    $file     = New-Object System.IO.FileStream($installer, [System.IO.FileMode]::Create)

    $buffer = New-Object byte[] 8192
    $totalRead = 0
    $lastPercent = -1

    while ($true) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }

        $file.Write($buffer, 0, $read)
        $totalRead += $read

        if ($total -gt 0) {
            $percent = [math]::Round(($totalRead / $total) * 100, 1)

            if ($percent -ne $lastPercent) {
                $bars = [math]::Floor($percent)
                $left = 100 - $bars

                $barText = "[" + ("=" * $bars) + (" " * $left) + "] $percent%"
                Write-Host $barText
                $lastPercent = $percent
            }
        }
    }

    $file.Close()
    $stream.Close()
    $response.Close()

    Write-Host "`nDownload completed!" -ForegroundColor Green
    Add-Content $logFile "Download completed: $(Get-Date)"

    # -------------------------------
    # INSTALAÇÃO ALL USERS
    # -------------------------------
    Write-Host "`nInstalling Visual Studio Code (ALL USERS)..." -ForegroundColor Cyan

    # /ALLUSERS=1 → instala para todos os usuários
    $arguments = "/VERYSILENT /NORESTART /ALLUSERS=1 /LOG=""$logFile"""

    $proc = Start-Process -FilePath $installer -ArgumentList $arguments -PassThru

    while (-not $proc.HasExited) {
        Write-Host "[================ INSTALLING ================]"
        Start-Sleep -Seconds 1
    }

    Add-Content $logFile "Installer exit code: $($proc.ExitCode)"

    Write-Host "`nInstallation finished (exit code: $($proc.ExitCode))" -ForegroundColor Green

    # -------------------------------
    # CONFIRMAÇÃO DA INSTALAÇÃO
    # -------------------------------
    Write-Host "`nChecking installation..." -ForegroundColor Cyan

    $paths = @(
        "C:\Program Files\Microsoft VS Code\Code.exe",
        "C:\Program Files (x86)\Microsoft VS Code\Code.exe"
    )

    $installed = $false

    foreach ($p in $paths) {
        if (Test-Path $p) {
            Write-Host "VS Code installed at: $p" -ForegroundColor Green
            Add-Content $logFile "VS Code installed at: $p"
            $installed = $true
        }
    }

    if (-not $installed) {
        Write-Host "VS Code installation NOT FOUND." -ForegroundColor Red
        Add-Content $logFile "VS Code installation NOT FOUND."
    }

    Add-Content $logFile "End: $(Get-Date)"
}

Write-Host "`nProcess completed on $computer." -ForegroundColor Green
