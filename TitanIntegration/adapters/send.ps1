param($Data, [hashtable]$Options)
& (Get-Module TitanIntegration) { param($p, $o) Send-TitanFile $p $o } ([string]$Data) $Options
