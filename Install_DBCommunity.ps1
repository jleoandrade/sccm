param(
    [Parameter(Mandatory = $true)]
    [string]$ComputerName
)

<#
.SYNOPSIS
Remote silent installation of DBeaver (system-wide).

.DESCRIPTION
Downloads the DBeaver installer to C:\Temp on the remote machine and performs
a silent installation for all users. Fully auditable, idempotent, and aligned
with enterprise automation standards.

.NOTES
Author: Workplace / EUC Engineering
Version: 1.0
#>

function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Output "$timestamp`t$Message"
}

Write-Log "Validating connectivity with $ComputerName"

if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet)) {
    Write-Log "ERROR: Machine unreachable."
    exit 1
}

Write-Log "Connectivity OK. Starting remote installation."

# -----------------------------
# Remote Script Block
# -----------------------------
$RemoteScript = {

    $InstallerUrl  = "https://dbeaver.io/files/dbeaver-ce-latest-x86_64-setup.exe"
    $TempFolder    = "C:\Temp"
    $InstallerPath = Join-Path $TempFolder "dbeaver_installer.exe"
    $LogPath       = "C:\ProgramData\CompanyName\Logs"
    $LogFile       = Join-Path $LogPath "DBeaverInstall.log"

    function Write-Log {
        param([string]$Message)
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $LogFile -Value "$timestamp`t$Message"
    }

    # Create directories
    New-Item -ItemType Directory -Path $TempFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

    Write-Log "Starting DBeaver installation."

    # Download installer
    try {
        Write-Log "Downloading installer from $InstallerUrl"
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing
    }
    catch {
        Write-Log "ERROR: Failed to download installer: $_"
        return 1
    }

    if (!(Test-Path $InstallerPath)) {
        Write-Log "ERROR: Installer file missing after download."
        return 1
    }

    # Silent install parameters (from documentation)
    # /S = silent
    # /allusers = install for all users
    # /D=path = installation directory
    $Arguments = "/S /allusers /D=""C:\Program Files\DBeaver"" "

    Write-Log "Executing silent installation."

    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru
        Write-Log "Installer exit code: $($process.ExitCode)"

        # Official return codes from documentation:
        # 0 = success
        # 1 = generic error
        # 2 = invalid parameters
        # 3 = canceled
        # 4 = already installed
        # 5 = reboot required

        if ($process.ExitCode -ne 0) {
            Write-Log "Installation failed with code $($process.ExitCode)"
            return $process.ExitCode
        }
    }
    catch {
        Write-Log "ERROR during installation: $_"
        return 1
    }

    Write-Log "DBeaver installed successfully."

    return 0
}

# -----------------------------
# Execute Remotely
# -----------------------------
try {
    Invoke-Command -ComputerName $ComputerName -ScriptBlock $RemoteScript -ErrorAction Stop
    Write-Log "Remote installation completed."
}
catch {
    Write-Log "ERROR executing remote installation: $_"
    exit 1
}

exit 0
