<#
.SYNOPSIS
  DEPRECATED - superseded by claude-ssh-solutions\Setup-ClaudeDockerHost.ps1.

  Manage the persistent Tailscale-connected Claude Code box (for phone access).

.NOTES
  DEPRECATED. Use claude-ssh-solutions\Setup-ClaudeDockerHost.ps1 instead. It does the same
  up/down/status job against a refactored compose file that additionally:
    - pins the Compose project name, so volume names are stable (the `docker_claude-home` name
      referenced in this repo's docs predates a directory rename and matches nothing)
    - defaults the workspace bind mounts, so it no longer fails on a machine without the
      SharePoint/OneDrive folders synced
    - creates the tmux 'work' session at container boot instead of on first manual attach
    - binds ttyd to loopback by default (it runs --writable with NO authentication)

  For phone access specifically, prefer Remote Control over SSH entirely - it needs no inbound
  ports and no VPN. See claude-ssh-solutions\docs\ANDROID.md.

  This script still works and is left in place for the existing Unraid deployment.

.DESCRIPTION
  Wraps the "remote" compose profile. On first run, put TS_AUTHKEY in a .env
  file (see .env.example). Once up, SSH in from any tailnet device:
      ssh node@claude-code
  then start work, ideally inside tmux:
      tmux new -A -s work
      cd /workspace/_pallas && claude

.PARAMETER Action
  up | down | status | logs | ssh-info   (default: status)

.EXAMPLE
  .\remote.ps1 up
  .\remote.ps1 status
  .\remote.ps1 down
#>
param(
    [ValidateSet('up', 'down', 'status', 'logs', 'ssh-info')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

switch ($Action) {
    'up' {
        docker compose build
        docker compose --profile remote up -d claude-remote
        Start-Sleep -Seconds 3
        docker compose exec claude-remote tailscale status
    }
    'down' {
        docker compose --profile remote down
    }
    'status' {
        docker compose --profile remote ps
        docker compose exec claude-remote tailscale status 2>$null
    }
    'logs' {
        docker compose exec claude-remote sh -c 'cat /var/log/tailscaled.log'
    }
    'ssh-info' {
        Write-Host "Tailnet hostname / IP:"
        docker compose exec claude-remote tailscale ip -4
        Write-Host "`nConnect from a tailnet device (e.g. phone SSH app):"
        Write-Host "  ssh node@claude-code"
    }
}
