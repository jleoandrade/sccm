Get-Printer | Where-Object { $_.Name -notmatch "OneNote|Microsoft|Fax" -and $_.Type -notmatch "Local" } | Remove-Printer 
Start-Process GPupdate -ArgumentList "/force" -Wait -NoNewWindow

$RegPath = "HKCU:\SOFTWARE\PSEG\Packages\FixCitrixFreezing"
if (-Not (Get-Item -Path $RegPath -ErrorAction SilentlyContinue)){
    New-Item -Path $RegPath -Force | Out-Null
}

New-ItemProperty -Path $RegPath -Name "Application Name" -Value "FixCitrixFreezing" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegPath -Name "Application Version" -Value "1.0" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegPath -Name "Installed" -Value (get-date).ToString() -PropertyType String -Force | Out-Null
New-ItemProperty -Path $RegPath -Name "Installed By" -Value $env:USERNAME -PropertyType String -Force | Out-Null