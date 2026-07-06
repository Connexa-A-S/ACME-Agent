<#
Imports the renewed certificate into a Java keystore (JKS or PKCS12) via keytool, for
Tomcat and other Java apps (Confluence, Jira, etc.), then optionally restarts a service.

Requires OutputFormat = pfx (keytool imports from the PKCS12) and PfxPassword in hooks.json.

hooks.json:
  "JavaKeystore": {
    "Enabled": true,
    "KeytoolPath": "keytool",
    "KeystorePath": "C:\\app\\conf\\keystore.jks",
    "KeystorePassword": "changeit",
    "Alias": "tomcat",
    "StoreType": "JKS",
    "RestartService": "Tomcat9"
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
    $jk = $config.JavaKeystore
    if (-not $jk -or -not $jk.Enabled) {
        Write-HookLog "Java keystore hook disabled in hooks.json. Skipping."
        exit 0
    }

    if ($Format -ne "pfx") { throw "Java keystore hook requires OutputFormat = pfx." }
    $pfx = Join-Path $CurrentPath "certificate.pfx"
    if (-not (Test-Path -LiteralPath $pfx)) { throw "PFX not found: $pfx" }

    $pfxPassword = [string]$config.PfxPassword
    if ([string]::IsNullOrWhiteSpace($pfxPassword)) { throw "PfxPassword missing in hooks.json" }

    $keytool = if ($jk.KeytoolPath) { [string]$jk.KeytoolPath } else { "keytool" }
    $ksPath = [string]$jk.KeystorePath
    $ksPass = [string]$jk.KeystorePassword
    $alias = if ($jk.Alias) { [string]$jk.Alias } else { "tomcat" }
    $storeType = if ($jk.StoreType) { [string]$jk.StoreType } else { "PKCS12" }
    if ([string]::IsNullOrWhiteSpace($ksPath)) { throw "KeystorePath missing in hooks.json" }

    # Determine the source alias inside the PFX (keytool needs it to rename on import).
    $srcAlias = $null
    $listOut = & $keytool -list -keystore $pfx -storetype PKCS12 -storepass $pfxPassword 2>&1
    foreach ($line in $listOut) {
        if ($line -match "PrivateKeyEntry") { $srcAlias = ($line -split ",")[0].Trim(); break }
    }

    # Remove any existing entry with the destination alias so the import does not collide.
    if (Test-Path -LiteralPath $ksPath) {
        & $keytool -delete -alias $alias -keystore $ksPath -storepass $ksPass 2>&1 | Out-Null
    }

    Write-HookLog "Importing certificate into $ksPath (alias '$alias', type $storeType) ..."
    if ($srcAlias) {
        & $keytool -importkeystore -noprompt `
            -srckeystore $pfx -srcstoretype PKCS12 -srcstorepass $pfxPassword -srcalias $srcAlias `
            -destkeystore $ksPath -deststoretype $storeType -deststorepass $ksPass -destalias $alias 2>&1 | ForEach-Object { Write-HookLog $_ }
    }
    else {
        Write-HookLog "Could not determine source alias; importing all entries and keeping their aliases." "WARN"
        & $keytool -importkeystore -noprompt `
            -srckeystore $pfx -srcstoretype PKCS12 -srcstorepass $pfxPassword `
            -destkeystore $ksPath -deststoretype $storeType -deststorepass $ksPass 2>&1 | ForEach-Object { Write-HookLog $_ }
    }
    if ($LASTEXITCODE -ne 0) { throw "keytool importkeystore failed (exit $LASTEXITCODE)." }

    if ($jk.RestartService) {
        Write-HookLog "Restarting service '$($jk.RestartService)' ..."
        Restart-Service -Name ([string]$jk.RestartService) -Force
    }

    Write-HookLog "Java keystore updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
