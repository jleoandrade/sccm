$computer = Read-Host "Enter the remote computer name"
$term = Read-Host "Enter the registry key name you want to search for (e.g., Bentley\\CONNECTIONClient)"

Invoke-Command -ComputerName $computer -ScriptBlock {

    param($term)

    Write-Host "`n=== Searching for registry keys containing '$term' ===" -ForegroundColor Cyan

    $hives = @(
        "HKLM:\",
        "HKCU:\",
        "HKCR:\",
        "HKU:\"
    )

    foreach ($hive in $hives) {

        try {
            Get-ChildItem -Path $hive -Recurse -ErrorAction SilentlyContinue | ForEach-Object {

                # Clean registry path
                $cleanPath = $_.Name.Replace("Microsoft.PowerShell.Core\Registry::","")

                # Check if it contains the search term
                if ($cleanPath -match [regex]::Escape($term)) {
                    Write-Host "Key found: $cleanPath" -ForegroundColor Green
                }
            }
        } catch {}
    }
} -ArgumentList $term
