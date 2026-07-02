param(
    [Parameter(Mandatory)][string]$CertificatePath,
    [Parameter(Mandatory)][string]$CurrentPath,
    [Parameter(Mandatory)][string]$VersionPath,
    [Parameter(Mandatory)][string]$MetadataPath,
    [Parameter(Mandatory)][string]$Format,
    [string]$ServiceId,
    [string]$ServiceName,
    [string]$CustomerNumber,
    [string]$Domain,
    [string]$Fingerprint,
    [string]$PreviousFingerprint
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Uploader = Join-Path $ScriptRoot "Upload-FortiGateCert.ps1"
$ConfigPath = Join-Path $ScriptRoot "fortigate.xml"

if (-not (Test-Path -LiteralPath $Uploader)) {
    Write-Error "Upload-FortiGateCert.ps1 not found: $Uploader"
    exit 3
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "FortiGate config not found: $ConfigPath. Copy fortigate.example.xml to fortigate.xml and configure it."
    exit 3
}

[xml]$Config = Get-Content -LiteralPath $ConfigPath
$PfxPass = [string]$Config.FortiGateCertSync.PfxPassword
if ([string]::IsNullOrWhiteSpace($PfxPass)) {
    Write-Error "PfxPassword missing in fortigate.xml"
    exit 3
}

$PfxFile = Get-ChildItem -LiteralPath $CurrentPath -File -Filter "*.pfx" | Select-Object -First 1
if (-not $PfxFile) {
    Write-Error "No .pfx file found in current certificate path: $CurrentPath. Set agent Format to pfx."
    exit 2
}

Write-Host "Deploying PFX to FortiGate targets. Service=$ServiceName Domain=$Domain File=$($PfxFile.FullName)"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Uploader -ConfigPath $ConfigPath -PfxFile $PfxFile.FullName -PfxPass $PfxPass
exit $LASTEXITCODE
