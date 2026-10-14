$ErrorActionPreference = 'Stop'
$module = Import-Module "$PSScriptRoot/../TitanIntegration/TitanIntegration.psd1" -Force -PassThru
$pass = 0
function Check($Name, $Actual, $Expected) {
  if ("$Actual" -cne "$Expected") { throw "$Name : got [$Actual], expected [$Expected]" }
  $script:pass++
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('titan-module-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
$location = Get-Location
try {
  $cache = New-Item -ItemType Directory -Path "$root/cache"
  $legacy = New-Item -ItemType Directory -Path "$root/legacy"
  $hash = 'A' * 64
  $other = 'B' * 64
  New-Item -ItemType File -Path "$legacy/prod-source-$hash.cache" | Out-Null
  New-Item -ItemType File -Path "$legacy/prod-other-$other.cache" | Out-Null
  $index = & $module { param($d,$l) Get-TitanCache $d 'prod-source' 1 $l } $cache.FullName $legacy.FullName
  Check 'migrated hash suppresses' $index.ContainsKey($hash) $true
  Check 'matching legacy marker retired' (Test-Path "$legacy/prod-source-$hash.cache") $false
  Check 'other scope retained' (Test-Path "$legacy/prod-other-$other.cache") $true
  Check 'migration provenance' @(Get-ChildItem $cache -Filter '*.cutover.*.cache').Count 1
  $index = & $module { param($d,$l) Get-TitanCache $d 'prod-source' 1 $l } $cache.FullName $legacy.FullName
  Check 'migration is idempotent' @(Get-ChildItem $cache).Count 1
  $stamp = [datetime]::UtcNow.AddHours(-25).ToString("yyyyMMdd'T'HHmmssfffffff'Z'")
  $old = New-Item -ItemType File -Path "$cache/$stamp.prod-source.ack.$other.cache"
  $old.LastWriteTimeUtc = [datetime]::UtcNow
  $index = & $module { param($d) Get-TitanCache $d 'prod-source' 1 } $cache.FullName
  Check 'fresh clone mtime does not prevent expiry' $index.ContainsKey($other) $false
  Check 'expired file removed' (Test-Path $old.FullName) $false
  $stamp = [datetime]::UtcNow.AddHours(-23).ToString("yyyyMMdd'T'HHmmssfffffff'Z'")
  $young = New-Item -ItemType File -Path "$cache/$stamp.prod-source.ack.$other.cache"
  $young.LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-100)
  $index = & $module { param($d) Get-TitanCache $d 'prod-source' 1 } $cache.FullName
  Check 'old mtime does not expire young acknowledgement' $index.ContainsKey($other) $true
  Set-Content -LiteralPath "$legacy/prod-source-$other.cache" -Value 'not empty'
  $refused = $false
  try { & $module { param($d,$l) Get-TitanCache $d 'prod-source' 1 $l } $cache.FullName $legacy.FullName | Out-Null }
  catch { $refused = $true }
  Check 'nonempty legacy refuses' $refused $true
  Check 'refused file retained' (Test-Path "$legacy/prod-source-$other.cache") $true

  $global:TitanCalls = [Collections.Generic.List[object]]::new()
  $global:TitanLoginThrows = $false
  function global:Invoke-RestMethod {
    param($Method,$Uri,$Body,$ContentType,$Headers,$TimeoutSec)
    $global:TitanCalls.Add([pscustomobject]@{ uri=$Uri; body=$Body; headers=$Headers })
    if ($Uri -like '*/login') {
      if ($global:TitanLoginThrows) { throw [TimeoutException]::new('original login timeout') }
      return [pscustomobject]@{ statusCode=0; token='synthetic'; userName='test' }
    }
    $id = ($Body | ConvertFrom-Json).externalRefID
    if ($id -eq 'transport') { throw [TimeoutException]::new('original transport failure') }
    [pscustomobject]@{ status=$(if ($id -eq 'rejected') { 1 } else { 0 }); messages=@() }
  }
  $config = @{
    keepdays=1; environment='prod'; division='send'
    cache=@{directory="$root/send-cache"; legacy_directory=$null}
    titan=@{base_url='https://api.example';email='test@example';password='synthetic';app_type=4;login_path='/login';order_path='/order';timeout_sec=1}
  }
  $body = '{"externalRefID":"accepted","location":"test","status":"Delivered","deliveryQuantity":7500.0000}'
  $result = @(& $module { param($p,$c) Send-TitanPayloads $p $c } @($body) $config)
  Check 'application success' $result[0].ok $true
  Check 'exact body sent' $global:TitanCalls[1].body $body
  Check 'token header' $global:TitanCalls[1].headers.token 'synthetic'
  Check 'one acknowledgement' @(Get-ChildItem $config.cache.directory -Filter '*.ack.*.cache').Count 1
  $result = @(& $module { param($p,$c) Send-TitanPayloads $p $c } @($body) $config)
  Check 'same payload suppressed' $result.Count 0
  Check 'cache skips login and post' $global:TitanCalls.Count 2
  $batch = @(
    '{"externalRefID":"rejected","location":"test","status":"Delivered"}'
    '{"externalRefID":"transport","location":"test","status":"Delivered"}'
    '{"externalRefID":"later","location":"test","status":"Delivered"}'
  )
  $result = @(& $module { param($p,$c) Send-TitanPayloads $p $c } $batch $config)
  Check 'batch continues' $result.Count 3
  Check 'rejection retained as result' $result[0].httpcode 1
  Check 'transport reported' $result[1].error 'original transport failure'
  Check 'later success retained' $result[2].ok $true
  Check 'only successes cached' @(Get-ChildItem $config.cache.directory -Filter '*.ack.*.cache').Count 2
  Check 'one login per sending batch' @($global:TitanCalls | Where-Object uri -like '*/login').Count 2
  $before = $global:TitanCalls.Count
  $config.environment='test'
  & $module { param($p,$c) Send-TitanPayloads $p $c } @($body) $config | Out-Null
  Check 'environment cache isolated' ($global:TitanCalls.Count - $before) 2
  $before = $global:TitanCalls.Count
  $global:TitanLoginThrows = $true
  $failure = $null
  try {
    & $module { param($p,$c) Send-TitanPayloads $p $c } @('{"externalRefID":"auth","status":"Delivered","location":"test"}') $config | Out-Null
  } catch { $failure = $_.Exception }
  Check 'login exception preserved' ($failure -is [TimeoutException]) $true
  Check 'login timeout message preserved' $failure.Message 'original login timeout'
  Check 'login failure sends no order' ($global:TitanCalls.Count - $before) 1
  $global:TitanLoginThrows = $false

  $maps = New-Item -ItemType Directory -Path "$root/maps"
  'tmw_code,tmw_tcn,titan_name', 'terminal,T-1,Terminal' | Set-Content "$maps/map-tmw-titan-terminal.csv"
  'tmw_code,titan_name', 'fuel,Fuel' | Set-Content "$maps/map-tmw-titan-fuel.csv"
  'tmw_code,titan_name', 'supplier,Terminal Supplier' | Set-Content "$maps/map-tmw-titan-terminal-supplier.csv"
  'tmw_code,titan_name', 'done,Delivered' | Set-Content "$maps/map-tmw-titan-status.csv"
  'tmw_code,titan_location_id,titan_name', 'store,100001,"0001 - Town, AA"' | Set-Content "$maps/map-tmw-titan-location.csv"
  $config.mappings=$maps.FullName
  $config.supplier='Supplier'
  $config.customer='Customer'
  $raw = [pscustomobject]@{
    externalRefID='runner'; source_store='store'; source_store_state='AA'; source_status='done';
    source_tcn='T-1'; source_shipper='terminal'; source_supplier='supplier'; source_cmd_code='fuel'; deliveryQuantity=12.25
  }
  $payload = & $module { param($r,$c) ConvertTo-TitanJson (ConvertTo-TitanOrders @($r) $c)[0] } $raw $config
  $parsed = $payload | ConvertFrom-Json
  Check 'private supplier from settings' $parsed.supplier 'Supplier'
  Check 'private customer from settings' $parsed.customer 'Customer'
  Check 'private location map' $parsed.location '0001 - Town, AA'
  Check 'blank property omitted' ($payload.Contains('trackingNumber')) $false
  $settings = @{} + $config
  $settings.src = @{adapter='sql';args=@{Query='synthetic';ConnectionString='synthetic';OutputAs='DataTables'}}
  $settings.purgefiles='*.log'
  $settings.filename_date_format='yyyyMMdd'
  $file = Join-Path $root 'settings.json'
  $settings | ConvertTo-Json -Depth 8 | Set-Content $file
  $table = [Data.DataTable]::new()
  foreach ($property in $raw.PSObject.Properties) { [void]$table.Columns.Add($property.Name, $property.Value.GetType()) }
  $row = $table.NewRow()
  foreach ($property in $raw.PSObject.Properties) { $row[$property.Name]=$property.Value }
  $table.Rows.Add($row)
  $global:TitanTable = $table
  function global:Invoke-Sqlcmd { param($Query,$ConnectionString,$OutputAs) Write-Output -NoEnumerate $global:TitanTable }
  $before = $global:TitanCalls.Count
  Invoke-TitanIntegration $file
  Check 'real runner sent once' ($global:TitanCalls.Count - $before) 2
  Check 'default daily log in caller folder' (Test-Path (Join-Path $root ('{0:yyyyMMdd}.log' -f (Get-Date)))) $true
  Check 'transient manifest removed' (Test-Path "$root/.titan-orders.json") $false
  Check 'module folder has no cache' (Test-Path "$PSScriptRoot/../TitanIntegration/cache") $false
  $before = $global:TitanCalls.Count
  Invoke-TitanIntegration $file -WhatIf
  Check 'WhatIf has no transport' $global:TitanCalls.Count $before
  $factory = New-TitanIntegrationConfig $settings
  Check 'filename cleanup flag passed' $factory.filename_date_format 'yyyyMMdd'
} finally {
  Set-Location $location
  Remove-Item Function:\Invoke-RestMethod, Function:\Invoke-Sqlcmd -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $root -Recurse -Force
}
"$pass checks passed"
