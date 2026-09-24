# ============================================
# LIST OF COMPUTERS
# ============================================
$Computers = @(

"1583808A"
)

# ============================================
# REMOTE SCRIPT EXECUTED ON CLIENT
# ============================================
Invoke-Command -ComputerName $Computers -ScriptBlock {
    Write-Host "--- Starting Repair on $env:COMPUTERNAME ---" -ForegroundColor Cyan

    # 1. DISM & SFC (System Integrity)
    # Note: DISM might take a while over the network
    DISM.exe /Online /Cleanup-Image /RestoreHealth
    sfc /scannow

    # 2. Reset Microsoft Store Services
    $StoreService = Get-Service -Name "InstallService" -ErrorAction SilentlyContinue
    if ($StoreService) {
        Set-Service -Name "InstallService" -StartupType Automatic
        Restart-Service -Name "InstallService"
    }

    # 3. Network Reset (Clear Proxy & DNS)
    Set-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0
    netsh winsock reset
    ipconfig /flushdns

    Write-Host "--- Repair finished on $env:COMPUTERNAME ---" -ForegroundColor Green
} -ErrorAction SilentlyContinue
