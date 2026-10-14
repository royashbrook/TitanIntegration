# TitanIntegration

For a carrier order feed using the Titan API. SQL or another DataAgent source supplies the rows, private CSV mappings normalize them, and the API receives the resulting order payloads. This module does not contain customer labels, mappings, endpoints, credentials or retained state.

```powershell
Import-Module TitanIntegration -RequiredVersion 1.0.0
Invoke-TitanIntegration "$PSScriptRoot/settings.json"
```

The module pins DataAgent 0.7.5, Add-PrefixForLogging 1.0.0.3 and Clear-Files 1.2.0.0. Install packages separately from the feed. Give each feed its own settings and working folder. The standard runner writes `yyyyMMdd.log` in that folder. A SQL source additionally needs SqlServer 22.4.5.1, the source adapter's pin.

Settings use a DataAgent `src` entry and `keepdays`, `purgefiles`, `filename_date_format` / `filename_date_pattern` for log cleanup. Supply `mappings` (a caller-owned directory), `supplier`, `customer`, `environment`, `division`, and `cache.directory`. The CSV filenames and columns match the existing TMW-to-Titan mapping shape. `titan` supplies `base_url`, `email`, `password`, `app_type`, `login_path`, `order_path` and `timeout_sec`. `env:NAME` references are resolved by DataAgent. The source query and recipient routing belong to the caller, not the package.

## Delivery and cache

The client omits null/blank fields while retaining payload property order. The transient `.titan-orders.json` holds exact JSON wire strings and is removed after the send pass. A payload change has a different UTF-8 SHA256 identity. A source timestamp change alone does not change that identity.

One login serves a batch. Only application `status = 0` writes an empty acknowledgement marker. An application rejection produces a result and permits later rows. A transport exception produces a failed result, permits later rows, and fails the feed after reporting the batch. A successful HTTP request is not itself application acknowledgement.

Markers live in the caller's cache, never in the installed package. Names contain UTC timestamps, environment/division scope, provenance (`ack` or `cutover`) and payload hash. Expiry uses that timestamp and the configured `keepdays`, not filesystem mtime. An unexpired marker suppresses both login and POST. After expiry the ordinary source still determines whether a payload is sent again.

To transition an existing empty-marker store, explicitly set `cache.legacy_directory`. Only matching `<environment>-<division>-<hash>.cache` markers are moved. A new `cutover` marker is written before removing the old file. Other scopes and unrelated files are left alone. Nonempty legacy markers refuse migration. This is idempotent across a partial transition.

The cutover timestamp is a retention epoch, **not** the last delivery time. Empty files can be deleted and recreated with identical bytes without a Git diff, so their last acknowledgement age cannot generally be reconstructed from Git. The transition conservatively grants each migrated marker a fresh retention interval. Review that one-time extension before adopting it. An `ack` marker records an actual application acknowledgement. Do not run old and new writers against the same scope during cutover.

`-WhatIf` on the entrypoint performs no source, cleanup, migration or delivery work. Tests use synthetic mappings and stubbed providers. No live vendor call is needed to test the module.
