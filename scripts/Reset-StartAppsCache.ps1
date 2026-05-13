#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$NoRestartExplorer)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot "src\ClientCBS.Tools.psm1"

Import-Module $modulePath -Force
Reset-ClientCBSStartAppsCache -NoRestartExplorer:$NoRestartExplorer
