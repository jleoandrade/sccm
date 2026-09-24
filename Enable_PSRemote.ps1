# Computer List
$Computers = @(

"162.22.34.88"

)

# Explicit Path to PsExec
$PsExecPath = "C:\Temp\PSTools\psexec.exe" 
$LogPath = "C:\temp\psremote.csv"

# Ensure the local C:\temp folder exists
if (!(Test-Path "C:\temp")) { 
    New-Item -Path "C:\temp" -ItemType Directory | Out-Null 
}

Write-Host "Starting PSRemoting activation process..." -ForegroundColor Yellow

foreach ($Computer in $Computers) {
    Write-Host "------------------------------------------" -ForegroundColor Gray
    Write-Host "Processing: $Computer" -ForegroundColor Cyan
    
    # Check if PsExec exists before running
    if (Test-Path $PsExecPath) {
        # Executes the command remotely
        # -s: System account | -d: Don't wait | -accepteula: Suppresses the license dialog
        $null = & $PsExecPath \\$Computer -s -d -accepteula cmd /c "powershell Enable-PSRemoting -Force" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $Status = "Command Sent Successfully"
            Write-Host "Success: Activation command triggered for $Computer" -ForegroundColor Green
        } else {
            $Status = "Trigger Failed"
            Write-Host "Error: Could not reach $Computer or Access Denied" -ForegroundColor Red
        }
    } else {
        $Status = "PsExec.exe not found"
        Write-Host "Error: PsExec not found at $PsExecPath" -ForegroundColor Red
    }

    # Prepare log data
    $LogEntry = [PSCustomObject]@{
        ComputerName = $Computer
        Timestamp    = (Get-Date -Format "MM/dd/yyyy HH:mm:ss")
        Status       = $Status
    }

    # Export/Append to the CSV file
    $LogEntry | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Delimiter "," -Append
}

Write-Host "`n[FINISHED] Check the log file at: $LogPath" -ForegroundColor Yellow
