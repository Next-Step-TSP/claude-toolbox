<#
.SYNOPSIS
  Build (if needed) and launch the Claude Code container.

.DESCRIPTION
  Convenience wrapper around docker compose. Mounts a project folder into the
  container at /workspace and starts Claude Code interactively.

.PARAMETER Project
  Path to the project folder you want Claude to work on. Defaults to the
  ./workspace folder beside this script.

.PARAMETER Shell
  Drop into a bash shell instead of launching Claude Code.

.EXAMPLE
  .\run.ps1
  .\run.ps1 -Project "C:\Users\MarkPrescott\source\myrepo"
  .\run.ps1 -Shell
#>
param(
    [string]$Project,
    [switch]$Shell
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Build the image (no-op if already built and unchanged).
docker compose build

$composeArgs = @('compose', 'run', '--rm')

# Override the workspace mount if a project path was supplied.
if ($Project) {
    if (-not (Test-Path $Project)) { throw "Project path not found: $Project" }
    $full = (Resolve-Path $Project).Path
    $composeArgs += @('-v', "${full}:/workspace")
}

$composeArgs += 'claude'
if ($Shell) { $composeArgs += 'bash' }

& docker @composeArgs
