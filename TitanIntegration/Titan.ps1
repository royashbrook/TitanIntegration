function Get-TitanMap($path, $keyColumn, $valueColumn) {
  $map = @{}
  if (Test-Path $path) {
    foreach ($row in (Import-Csv $path)) {
      $key = "$($row.$keyColumn)".Trim()
      if ($key -ne '') { $map[$key] = "$($row.$valueColumn)".Trim() }
    }
  }
  return $map
}

function ConvertTo-TitanOrders($dt, $cfg) {
  $mapDir = $cfg.mappings
  $terminalMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-terminal.csv') 'tmw_tcn' 'titan_name'
  $terminalShipperMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-terminal.csv') 'tmw_code' 'titan_name'
  $fuelMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-fuel.csv') 'tmw_code' 'titan_name'
  $supplierMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-terminal-supplier.csv') 'tmw_code' 'titan_name'
  $statusMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-status.csv') 'tmw_code' 'titan_name'
  $locationMap = Get-TitanMap (Join-Path $mapDir 'map-tmw-titan-location.csv') 'tmw_code' 'titan_name'

  $locationIndex = @{}
  $ambiguousLocations = @{}
  foreach ($row in (Import-Csv (Join-Path $mapDir 'map-tmw-titan-location.csv'))) {
    $id = "$($row.titan_location_id)".Trim()
    if ($id.Length -lt 4) { continue }
    $name = "$($row.titan_name)".Trim()
    $state = [regex]::Match($name, ',\s*([A-Za-z]{2})\s*$')
    if (-not $state.Success) { continue }
    $key = $id.Substring($id.Length - 4) + '|' + $state.Groups[1].Value.ToUpper()
    if ($locationIndex.ContainsKey($key)) { $ambiguousLocations[$key] = $true }
    else { $locationIndex[$key] = $name }
  }

  $unmapped = @{}
  $flag = {
    param($dimension, $value)
    if ("$value".Trim() -eq '') { return }
    if (-not $unmapped.ContainsKey($dimension)) { $unmapped[$dimension] = @{} }
    $unmapped[$dimension]["$value".Trim()] = $true
  }
  $map = {
    param($values, $value, $dimension, $hold)
    $key = "$value".Trim()
    if ($values.ContainsKey($key)) { return $values[$key] }
    & $flag $dimension $key
    if ($hold) { return $null }
    return $key
  }
  $resolveLocation = {
    param($consignee, $state)
    $code = "$consignee".Trim()
    if ($locationMap.ContainsKey($code)) { return $locationMap[$code] }
    $digits = $code -replace '[^0-9]', ''
    if ($digits.Length -lt 1 -or $digits.Length -gt 4) { return $null }
    $key = $digits.PadLeft(4, '0') + '|' + "$state".Trim().ToUpper()
    if ($ambiguousLocations.ContainsKey($key)) { return $null }
    if ($locationIndex.ContainsKey($key)) { return $locationIndex[$key] }
    return $null
  }
  $resolveTerminal = {
    param($tcn, $shipper)
    $tcn = "$tcn".Trim()
    if ($tcn -ne '' -and $terminalMap.ContainsKey($tcn)) { return $terminalMap[$tcn] }
    $shipper = "$shipper".Trim()
    if ($shipper -ne '' -and $terminalShipperMap.ContainsKey($shipper)) { return $terminalShipperMap[$shipper] }
    & $flag 'terminal' $(if ($tcn -ne '') { $tcn } else { $shipper })
    return ''
  }

  $orders = foreach ($row in $dt) {
    $location = & $resolveLocation $row.source_store $row.source_store_state
    if ([string]::IsNullOrWhiteSpace($location)) { & $flag 'location' "$($row.source_store)/$($row.source_store_state)" }
    $status = & $map $statusMap $row.source_status 'status' $true
    $delivered = ($status -eq 'Delivered')

    [PSCustomObject][ordered]@{
      externalRefID         = $row.externalRefID
      supplier              = $cfg.supplier
      customer              = $cfg.customer
      location              = $location
      fuelType              = & $map $fuelMap $row.source_cmd_code 'fuelType' $false
      deliveryQuantity      = $row.deliveryQuantity
      deliveryETADate       = $row.deliveryETADate
      deliveryETATime       = $row.deliveryETATime
      status                = $status
      trackingNumber        = ''
      contractLoadingNumber = ''
      deliveredGross        = if ($delivered) { $row.source_delivered_gross } else { $null }
      deliveredNet          = if ($delivered) { $row.source_delivered_net } else { $null }
      deliveryStartDate     = if ($delivered) { $row.source_dstart_date } else { $null }
      deliveryStartTime     = if ($delivered) { $row.source_dstart_time } else { $null }
      deliveryEndDate       = if ($delivered) { $row.source_dend_date } else { $null }
      deliveryEndTime       = if ($delivered) { $row.source_dend_time } else { $null }
      bolNumber             = if ($delivered) { $row.source_bol } else { $null }
      BolLiftDate           = if ($delivered) { $row.source_bol_lift_date } else { $null }
      BolLiftTime           = if ($delivered) { $row.source_bol_lift_time } else { $null }
      bolGross              = if ($delivered) { $row.source_bol_gross } else { $null }
      bolNet                = if ($delivered) { $row.source_bol_net } else { $null }
      terminalSupplier      = & $map $supplierMap $row.source_supplier 'terminalSupplier' $false
      terminal              = & $resolveTerminal $row.source_tcn $row.source_shipper
    }
  }

  foreach ($dimension in $unmapped.Keys) {
    $values = ($unmapped[$dimension].Keys | Sort-Object) -join ', '
    Write-Warning "ConvertTo-TitanOrders: UNMAPPED $dimension -> [$values]"
  }
  return @($orders)
}

function Get-TitanToken($cfg) {
  $base = $cfg.titan.base_url
  $email = $cfg.titan.email
  $pass = $cfg.titan.password
  $appType = if ([string]::IsNullOrWhiteSpace($cfg.titan.app_type)) { 4 } else { [int]$cfg.titan.app_type }

  if ([string]::IsNullOrWhiteSpace($base) -or
      [string]::IsNullOrWhiteSpace($email) -or
      [string]::IsNullOrWhiteSpace($pass)) {
    Write-Host 'Get-TitanToken: missing base_url / email / password'
    return $null
  }

  $loginPath = $cfg.titan.login_path
  $body = @{
    email             = $email
    password          = $pass
    isBuyerTPOCreated = $false
    appType           = $appType
  } | ConvertTo-Json

  try {
    $response = Invoke-RestMethod -Method Post -Uri ($base.TrimEnd('/') + $loginPath) -Body $body `
      -ContentType 'application/json' -TimeoutSec $cfg.titan.timeout_sec
    if ($response.statusCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($response.token)) {
      Write-Host ('Get-TitanToken: ok (user {0})' -f $response.userName)
      return $response.token
    }
    Write-Host ('Get-TitanToken: login rejected - statusCode={0} msg={1}' -f $response.statusCode, $response.statusMessage)
  }
  catch { Write-Host ('Get-TitanToken: login error - {0}' -f $_.Exception.Message) }
  return $null
}

function ConvertTo-TitanJson($row) {
  $payload = [ordered]@{}
  foreach ($property in $row.PSObject.Properties) {
    $value = $property.Value
    if ($null -ne $value -and "$value".Trim() -ne '') { $payload[$property.Name] = $value }
  }
  return ([PSCustomObject]$payload | ConvertTo-Json -Depth 10 -Compress)
}

function Get-TitanCache {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Scope,
    [Parameter(Mandatory)][ValidateRange(1, 3650)][int]$KeepDays,
    [string]$LegacyDirectory
  )
  New-Item -ItemType Directory -Path $Directory -Force | Out-Null
  $now = [datetime]::UtcNow
  $cutoff = $now.AddDays(-$KeepDays)
  $format = "yyyyMMdd'T'HHmmssfffffff'Z'"
  $prefix = [regex]::Escape($Scope)
  $index = @{}
  foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.cache' -File)) {
    if ($file.Name -notmatch "^(\d{8}T\d{13}Z)\.$prefix\.(ack|cutover)\.([A-Fa-f0-9]{64})\.cache$") { continue }
    $stamp = $Matches[1]
    $hash = $Matches[3]
    $at = [datetime]::ParseExact($stamp, $format, [cultureinfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
    if ($at -lt $cutoff) { Remove-Item -LiteralPath $file.FullName }
    else { $index[$hash] = $true }
  }
  if ($LegacyDirectory -and (Test-Path -LiteralPath $LegacyDirectory)) {
    $migrated = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $LegacyDirectory -Filter '*.cache' -File)) {
      if ($file.Name -notmatch "^$prefix-([A-Fa-f0-9]{64})\.cache$") { continue }
      $hash = $Matches[1]
      if ($file.Length -ne 0) { throw "Legacy marker is not empty: $($file.Name)" }
      # Empty-file Git history cannot identify a later same-byte acknowledgement.
      if (-not $index.ContainsKey($hash)) {
        $path = Join-Path $Directory "$($now.ToString($format)).$Scope.cutover.$hash.cache"
        New-Item -ItemType File -Path $path -ErrorAction Stop | Out-Null
        $index[$hash] = $true
      }
      Remove-Item -LiteralPath $file.FullName -ErrorAction Stop
      $migrated++
    }
    if ($migrated) { Write-Host "Cache: migrated $migrated $Scope markers at a retention cutover, not a delivery timestamp" }
  }
  return $index
}

function Send-TitanPayloads($payloads, $cfg) {
  $scope = "$($cfg.environment)-$($cfg.division)"
  $cacheDir = $cfg.cache.directory
  $index = Get-TitanCache -Directory $cacheDir -Scope $scope -KeepDays $cfg.keepdays -LegacyDirectory $cfg.cache.legacy_directory
  $uri = $cfg.titan.base_url.TrimEnd('/') + $cfg.titan.order_path
  $sha = [Security.Cryptography.SHA256]::Create()
  $token = $null

  try {
  $results = foreach ($json in $payloads) {
    $row = $json | ConvertFrom-Json
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-'
    if ($index.ContainsKey($hash)) { continue }

    if ([string]::IsNullOrWhiteSpace($token)) {
      $token = Get-TitanToken $cfg
      if ([string]::IsNullOrWhiteSpace($token)) { throw 'Titan: TFX login failed' }
    }

    try {
      $response = Invoke-RestMethod -Method Post -Uri $uri -Body $json -ContentType 'application/json' `
        -Headers @{ token = $token } -TimeoutSec $cfg.titan.timeout_sec
      $messages = if ($response.messages) { ($response.messages.message -join '; ') } else { '' }
      $ok = ($response.status -eq 0)
      if ($ok) {
        $stamp = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmssfffffff'Z'")
        New-Item -ItemType File -Path (Join-Path $cacheDir "$stamp.$scope.ack.$hash.cache") -ErrorAction Stop | Out-Null
        $index[$hash] = $true
      }
      [PSCustomObject]@{
        externalRefID = "$($row.externalRefID)"
        status        = $row.status
        ok            = $ok
        httpcode      = if ($ok) { 200 } else { $response.status }
        error         = $messages
        response      = if ($null -ne $response) { $response | ConvertTo-Json -Depth 6 -Compress } else { '' }
        sent          = $json
      }
    }
    catch {
      $body = "$($_.ErrorDetails.Message)"
      if ([string]::IsNullOrWhiteSpace($body)) { $body = "$($_.Exception.Message)" }
      [PSCustomObject]@{
        externalRefID = "$($row.externalRefID)"
        status        = $row.status
        ok            = $false
        httpcode      = $null
        error         = $_.Exception.Message
        response      = $body
        sent          = $json
      }
    }
  }

  return @($results)
  } finally { $sha.Dispose() }
}
