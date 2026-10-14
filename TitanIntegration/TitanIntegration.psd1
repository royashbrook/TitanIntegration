@{
  RootModule = 'TitanIntegration.psm1'
  ModuleVersion = '1.0.0'
  GUID = '4a4a9e15-5c51-423a-b9b5-9f8f209e913a'
  Author = 'Roy Ashbrook'
  CompanyName = 'ashbrook.io'
  Copyright = '(c) 2026 royashbrook. MIT License.'
  Description = 'Settings-driven order mapping and delivery to the Titan carrier API, with caller-owned mapping files and timestamped payload markers.'
  PowerShellVersion = '7.4'
  RequiredModules = @(
    @{ ModuleName = 'DataAgent'; RequiredVersion = '0.7.5' }
    @{ ModuleName = 'Add-PrefixForLogging'; RequiredVersion = '1.0.0.3' }
    @{ ModuleName = 'Clear-Files'; RequiredVersion = '1.2.0.0' }
  )
  FunctionsToExport = @('Invoke-TitanIntegration', 'New-TitanIntegrationConfig')
  AliasesToExport = @()
  CmdletsToExport = @()
  VariablesToExport = @()
  PrivateData = @{
    PSData = @{
      Tags = @('titan', 'orders', 'integration', 'dataagent')
      LicenseUri = 'https://github.com/royashbrook/TitanIntegration/blob/main/LICENSE'
      ProjectUri = 'https://github.com/royashbrook/TitanIntegration'
    }
  }
}
