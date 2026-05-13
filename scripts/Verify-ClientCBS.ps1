[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot "src\ClientCBS.Tools.psm1"

Import-Module $modulePath -Force
Show-ClientCBSState
