<#
.SYNOPSIS
  Installs the Connexa ACME PowerShell fetch agent as a scheduled task.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApiBaseUrl,
    [Parameter(Mandatory)][string]$ServiceApiKey,
    [ValidateSet("pfx", "pem")][string]$OutputFormat = "pfx",
    [string]$PfxPassword,
    [string]$InstallPath = "C:\ProgramData\Connexa\ACMEAgent",
    [int]$IntervalHours = 12,
    [string[]]$Hooks = @(),
    [string]$HooksPath,
    [switch]$StoreSecretsProtected
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Registering a SYSTEM scheduled task and locking down ACLs both require elevation.
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an elevated PowerShell (Run as Administrator)."
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Protect-Value {
    param([Parameter(Mandatory)][string]$Value)
    # Machine-scoped DPAPI so the SYSTEM scheduled task can decrypt it, regardless of
    # which admin account runs this installer. (User-scoped ConvertFrom-SecureString
    # would only be decryptable by the installing user, not by SYSTEM.)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $entropy = [Text.Encoding]::UTF8.GetBytes("CNXA-ACMEAgent")
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $entropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return @{ ProtectedValueB64 = [Convert]::ToBase64String($protected) }
}

if ($OutputFormat -eq "pfx" -and [string]::IsNullOrWhiteSpace($PfxPassword)) {
    throw "PfxPassword is required when OutputFormat is pfx"
}

New-DirectoryIfMissing -Path $InstallPath
New-DirectoryIfMissing -Path (Join-Path $InstallPath "logs")
New-DirectoryIfMissing -Path (Join-Path $InstallPath "certs")
$resolvedHooksPath = if ([string]::IsNullOrWhiteSpace($HooksPath)) { Join-Path $InstallPath "hooks" } else { $HooksPath }
New-DirectoryIfMissing -Path $resolvedHooksPath

# Lock the install tree down to SYSTEM + Administrators only. It holds the config
# (API key / PFX password), and the hooks that run as SYSTEM, so non-admin users
# must not be able to read secrets or drop in executable hooks. Inheritance is set
# so config.json and other files created below inherit the restrictive ACL.
# SIDs are used instead of names to stay correct on non-English Windows.
& icacls $InstallPath /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to harden ACLs on $InstallPath (icacls exit $LASTEXITCODE)."
}

$sourceScript = Join-Path $PSScriptRoot "CNXA-AcmeFetch.ps1"
if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "CNXA-AcmeFetch.ps1 not found next to installer"
}

Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $InstallPath "CNXA-AcmeFetch.ps1") -Force

$config = [ordered]@{
    ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
    OutputFormat = $OutputFormat
    OutputPath = Join-Path $InstallPath "certs"
    StatePath = Join-Path $InstallPath "state.json"
    LogPath = Join-Path $InstallPath "logs"
    RunHooksOnFirstDownload = $true
    HooksPath = $resolvedHooksPath
    Hooks = $Hooks
}

if ($StoreSecretsProtected) {
    $config.ServiceApiKey = Protect-Value -Value $ServiceApiKey
    if ($OutputFormat -eq "pfx") {
        $config.PfxPassword = Protect-Value -Value $PfxPassword
    }
}
else {
    $config.ServiceApiKey = $ServiceApiKey
    if ($OutputFormat -eq "pfx") {
        $config.PfxPassword = $PfxPassword
    }
}

$configPath = Join-Path $InstallPath "config.json"
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

$taskName = "Connexa ACME Agent"
$scriptPath = Join-Path $InstallPath "CNXA-AcmeFetch.ps1"
$argument = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null

Write-Host "Connexa ACME Agent installed."
Write-Host "Config: $configPath"
Write-Host "Task:   $taskName"
Write-Host "Run now with: Start-ScheduledTask -TaskName '$taskName'"
