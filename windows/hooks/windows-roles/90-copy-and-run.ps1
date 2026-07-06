<#
Generic hook: copy certificate files from the current folder to arbitrary paths
(for apps that read a cert/key from disk), then optionally restart a service and/or
run a command. Covers the long tail (HAProxy, Nginx/Apache on Windows, custom apps).

hooks.json:
  "CopyAndRun": {
    "Enabled": true,
    "Files": [ { "From": "cert.crt", "To": "C:\\app\\ssl\\server.crt" },
               { "From": "cert.key", "To": "C:\\app\\ssl\\server.key" } ],
    "RestartService": "myapp",
    "Command": ""
  }

Exit codes: 0 = OK/skip, 3 = fatal.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CertificatePath,
    [Parameter(Mandatory)][string] $CurrentPath,
    [Parameter(Mandatory)][string] $VersionPath,
    [Parameter(Mandatory)][string] $MetadataPath,
    [Parameter(Mandatory)][string] $Format,
    [string] $ServiceId,
    [string] $ServiceName,
    [string] $CustomerNumber,
    [string] $Domain,
    [string] $Fingerprint,
    [string] $PreviousFingerprint
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib\Common.ps1")

try {
    $config = Get-HookConfig -HookRoot $PSScriptRoot
    $cr = $config.CopyAndRun
    if (-not $cr -or -not $cr.Enabled) {
        Write-HookLog "CopyAndRun hook disabled in hooks.json. Skipping."
        exit 0
    }

    foreach ($file in @($cr.Files)) {
        if (-not $file -or -not $file.From -or -not $file.To) { continue }
        $src = Join-Path $CurrentPath ([string]$file.From)
        $dst = [string]$file.To
        if (-not (Test-Path -LiteralPath $src)) { throw "Source file not found: $src" }
        $dstDir = Split-Path -Parent $dst
        if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-HookLog "Copied $($file.From) -> $dst"
    }

    if ($cr.RestartService) {
        Write-HookLog "Restarting service '$($cr.RestartService)' ..."
        Restart-Service -Name ([string]$cr.RestartService) -Force
    }

    if ($cr.Command) {
        Write-HookLog "Running command: $($cr.Command)"
        & cmd.exe /c ([string]$cr.Command)
        if ($LASTEXITCODE -ne 0) { throw "Command exited with code $LASTEXITCODE." }
    }

    Write-HookLog "Done."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
