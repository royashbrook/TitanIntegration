. $PSScriptRoot/Titan.ps1

function Invoke-TitanIntegration {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory, Position = 0)][string]$Settings)
  $file = Get-Item -LiteralPath $Settings
  if (-not $PSCmdlet.ShouldProcess($file.DirectoryName, 'Invoke-TitanIntegration')) { return }
  $config = New-TitanIntegrationConfig $file.FullName
  $config.directory = $file.DirectoryName
  Invoke-DataAgent $config
}

function New-TitanIntegrationConfig {
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)]$Settings)
  if ($Settings -is [string]) { $Settings = Get-Content -LiteralPath $Settings -Raw | ConvertFrom-Json -AsHashtable }
  $config = @{
    src = $Settings.src
    fmt = @{ adapter = "$PSScriptRoot/adapters/payloads.ps1"; args = @{ Path = '.titan-orders.json'; Settings = $Settings } }
    dst = @{ adapter = "$PSScriptRoot/adapters/send.ps1"; args = @{ Settings = $Settings } }
  }
  foreach ($key in 'keepdays', 'purgefiles', 'filename_date_format', 'filename_date_pattern') {
    if ($Settings.ContainsKey($key)) { $config[$key] = $Settings[$key] }
  }
  $config
}

function Save-TitanPayloads($Data, $Options) {
  $rows = if ($Data[0] -is [Data.DataRow]) { @($Data | Select-Object $Data[0].Table.Columns.ColumnName) } else { @($Data) }
  l 'rows' | Write-Host
  $rows | Format-Table -Property * -AutoSize | Out-String -Width 4096 | Write-Host
  $payloads = @(foreach ($row in (ConvertTo-TitanOrders $rows $Options.Settings)) {
    if ([string]::IsNullOrWhiteSpace($row.location) -or [string]::IsNullOrWhiteSpace($row.status)) { continue }
    ConvertTo-TitanJson $row
  })
  # Store the wire strings, not reserialized numbers from a JSON round trip.
  ConvertTo-Json -InputObject $payloads | Set-Content -LiteralPath $Options.Path
}

function Send-TitanFile($Path, $Options) {
  try {
    $payloads = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    $results = @(Send-TitanPayloads $payloads $Options.Settings)
    if (-not $results.Count) { l 'No data available after mapping and cache' | Write-Host; return }
    $results | Format-Table -Property externalRefID, status, ok, httpcode, error -AutoSize | Out-String -Width 4096 | Write-Host
    foreach ($result in @($results.Where({-not $_.ok -and $null -ne $_.httpcode}))) {
      Write-Host "::warning title=Titan rejected $($result.externalRefID)::$($result.error)"
    }
    $failed = @($results.Where({-not $_.ok -and $null -eq $_.httpcode}))
    if ($failed.Count) { throw "Titan: $($failed.Count) post(s) failed" }
  } finally { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}

Export-ModuleMember -Function Invoke-TitanIntegration, New-TitanIntegrationConfig
