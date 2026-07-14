#requires -Version 7
# Installs the M365 / Azure admin modules into the image (AllUsers scope).
# Run during docker build by pwsh.

$ErrorActionPreference = 'Stop'
$ProgressPreference   = 'SilentlyContinue'   # huge speedup; no progress bars in build logs

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Ordered so the big one (Az) is obvious in the logs. Graph is intentionally the
# Authentication module plus only the commonly-used workload submodules.
$modules = @(
    'Az'                                # full Azure PowerShell (large)
    'Microsoft.Graph.Authentication'    # Connect-MgGraph, Invoke-MgGraphRequest
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Groups'
    'Microsoft.Graph.Sites'             # SharePoint sites
    'Microsoft.Graph.Files'             # drives / SharePoint+OneDrive files
    'Microsoft.Graph.Mail'
    'PnP.PowerShell'                    # SharePoint Online admin
    'ExchangeOnlineManagement'          # EXO
)

foreach ($m in $modules) {
    Write-Host "==> Installing $m"
    Install-Module -Name $m -Scope AllUsers -Force -AllowClobber -AcceptLicense
}

Write-Host '==> Installed module versions:'
Get-Module -ListAvailable -Name 'Az','Microsoft.Graph.*','PnP.PowerShell','ExchangeOnlineManagement' |
    Sort-Object Name, Version |
    Select-Object Name, Version |
    Format-Table -AutoSize
