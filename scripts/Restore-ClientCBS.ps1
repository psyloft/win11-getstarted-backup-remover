#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BackupPath,
    [switch]$RestoreStateRepository,
    [switch]$InstallMySQLite,
    [switch]$Force,
    [switch]$NoRestartShell
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot "src\ClientCBS.Tools.psm1"

Import-Module $modulePath -Force
Restore-ClientCBS `
    -BackupPath $BackupPath `
    -RestoreStateRepository:$RestoreStateRepository `
    -InstallMySQLite:$InstallMySQLite `
    -Force:$Force `
    -NoRestartShell:$NoRestartShell
