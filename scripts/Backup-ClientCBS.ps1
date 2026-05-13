#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BackupRoot,
    [switch]$InstallMySQLite
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot "src\ClientCBS.Tools.psm1"

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $projectRoot "backups"
}

Import-Module $modulePath -Force
Backup-ClientCBS -BackupRoot $BackupRoot -InstallMySQLite:$InstallMySQLite
