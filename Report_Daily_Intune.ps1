# Define file paths
$csvPath = "C:\Users\ServiceHLASMSWKS15\Downloads\intune_report.csv"
$excelPath = "C:\Users\ServiceHLASMSWKS15\Downloads\intune_report_summary.xlsx"

# 1. Import CSV and exclude the "User Phone" column
if (-not (Get-Module -ListAvailable -Name ImportExcel)) { 
    Install-Module -Name ImportExcel -Force -Scope CurrentUser -AllowClobber 
}

$data = Import-Csv -Path $csvPath -Delimiter (Get-Culture).TextInfo.ListSeparator | 
        Select-Object * -ExcludeProperty "User Phone"

# Export clean raw data to the base Excel file
$data | Export-Excel -Path $excelPath -WorksheetName "Devices"

# 2. Initialize Excel COM Object to build the exact Pivot Table layout
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false

$workbook = $excel.Workbooks.Open($excelPath)
$dataSheet = $workbook.Worksheets.Item("Devices")

# Create the dedicated 'summary' sheet
$summarySheet = $workbook.Worksheets.Add()
$summarySheet.Name = "summary"

# Define the source data range dynamically
$lastRow = $dataSheet.UsedRange.Rows.Count
$lastCol = $dataSheet.UsedRange.Columns.Count
$sourceRange = $dataSheet.Range($dataSheet.Cells(1, 1), $dataSheet.Cells($lastRow, $lastCol))

# Create Pivot Cache and insert the Pivot Table at cell A3
$pivotCache = $workbook.PivotCaches().Create([Microsoft.Office.Interop.Excel.XlPivotTableSourceType]::xlDatabase, $sourceRange)
$pivotTable = $pivotCache.CreatePivotTable($summarySheet.Range("A3"), "SummaryPivot")

# 3. Configure Rows -> 'OS Version'
$rowField = $pivotTable.PivotFields("OS Version")
$rowField.Orientation = [Microsoft.Office.Interop.Excel.XlPivotFieldOrientation]::xlRowField
$rowField.Position = 1

# 4. Configure Columns -> 'Compliance'
$colField = $pivotTable.PivotFields("Compliance")
$colField.Orientation = [Microsoft.Office.Interop.Excel.XlPivotFieldOrientation]::xlColumnField
$colField.Position = 1

# 5. Configure Value Field 1 -> Count of Device Name
$dataField1 = $pivotTable.PivotFields("Device Name")
$dataField1.Orientation = [Microsoft.Office.Interop.Excel.XlPivotFieldOrientation]::xlDataField
$dataField1.Function = [Microsoft.Office.Interop.Excel.XlConsolidationFunction]::xlCount
$dataField1.Name = "Count of Device Name " # Added trailing space to prevent name conflicts

# 6. Configure Value Field 2 -> Percentage of Grand Total
$dataField2 = $pivotTable.PivotFields("Device Name")
$dataField2.Orientation = [Microsoft.Office.Interop.Excel.XlPivotFieldOrientation]::xlDataField
$dataField2.Function = [Microsoft.Office.Interop.Excel.XlConsolidationFunction]::xlCount
$dataField2.Name = "Percentage"
$dataField2.Calculation = 8 # 8 represents xlPercentOfTotal calculation mode
$dataField2.NumberFormat = "0.00%"

# Save, close, and cleanly release COM objects from memory
$workbook.Save()
$workbook.Close()
$excel.Quit()

[System.Runtime.InteropServices.Marshal]::ReleaseComObject($summarySheet) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($dataSheet) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

# Open the final file for validation
Start-Process $excelPath
