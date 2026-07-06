<#
Deploys a renewed certificate to one or more AudioCodes devices (Mediant SBC / gateway)
via the device REST API. Uploads the PEM certificate and private key into a TLS context,
then optionally saves the configuration.

Requires the agent to use PEM output (OutputFormat = pem): reads cert.crt and cert.key.

IMPORTANT: AudioCodes REST paths and verbs vary by firmware version. The defaults below
match recent Mediant firmware, but verify them against your device's REST API reference
and override CertificateApiPath / PrivateKeyApiPath / UploadMethod in audiocodes.xml if
needed. "{id}" is replaced with the TLS context index.

Config: copy audiocodes.example.xml to audiocodes.xml next to this script.

Exit codes: 0 = OK, 2 = retry (no PEM yet), 3 = fatal / one or more devices failed.
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
$script:HadErrors = $false

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-Log {
    param([string] $Message, [ValidateSet("INFO","WARN","ERROR")] [string] $Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        $folder = Split-Path $script:LogPath -Parent
        if ($folder -and -not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
        Add-Content -Path $script:LogPath -Value $line
    }
}

function Get-XmlBool {
    param($Value, [bool] $Default = $false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    return [bool]::Parse([string]$Value)
}

function Invoke-AudioCodes {
    param(
        [string] $Method,
        [string] $Path,
        [string] $BodyText = $null
    )

    $params = @{
        Method     = $Method
        Uri        = "https://$script:AcHost$Path"
        TimeoutSec = 60
        Headers    = @{ Authorization = "Basic $script:AcAuth" }
    }
    if ($script:SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    if ($null -ne $BodyText) {
        $params.ContentType = "text/plain"
        $params.Body = $BodyText
    }

    return Invoke-RestMethod @params
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the AudioCodes hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "audiocodes.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy audiocodes.example.xml to audiocodes.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.AudioCodesCertSync

    $tlsId = if ($settings.TlsContextId) { [string]$settings.TlsContextId } else { "0" }
    $certApi = if ($settings.CertificateApiPath) { [string]$settings.CertificateApiPath } else { "/api/v1/files/tls/{id}/certificate" }
    $keyApi  = if ($settings.PrivateKeyApiPath) { [string]$settings.PrivateKeyApiPath } else { "/api/v1/files/tls/{id}/privateKey" }
    $uploadMethod = if ($settings.UploadMethod) { [string]$settings.UploadMethod } else { "PUT" }
    $saveApi = if ($settings.SaveConfigApiPath) { [string]$settings.SaveConfigApiPath } else { "/api/v1/actions/saveConfiguration" }
    $SaveConfig = Get-XmlBool $settings.SaveConfig $true
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCertificateCheck = Get-XmlBool $settings.SkipCertificateCheck $true

    $certApi = $certApi.Replace("{id}", $tlsId)
    $keyApi  = $keyApi.Replace("{id}", $tlsId)

    $certPem = [IO.File]::ReadAllText($certFile)
    $keyPem  = [IO.File]::ReadAllText($keyFile)

    foreach ($dev in $settings.Devices.Device) {
        $devName = [string]$dev.Name
        try {
            $script:AcHost = [string]$dev.Host
            $pair = "{0}:{1}" -f [string]$dev.Username, [string]$dev.Password
            $script:AcAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

            Write-Log "------------------------------------------------------------"
            Write-Log "AudioCodes: $devName ($script:AcHost), TLS context $tlsId"

            Write-Log "Uploading certificate ($uploadMethod $certApi) ..."
            Invoke-AudioCodes -Method $uploadMethod -Path $certApi -BodyText $certPem | Out-Null

            Write-Log "Uploading private key ($uploadMethod $keyApi) ..."
            Invoke-AudioCodes -Method $uploadMethod -Path $keyApi -BodyText $keyPem | Out-Null

            if ($SaveConfig) {
                Write-Log "Saving configuration ($saveApi) ..."
                Invoke-AudioCodes -Method "POST" -Path $saveApi | Out-Null
            }

            Write-Log "AudioCodes '$devName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on AudioCodes '$devName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next device." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "AudioCodes sync finished with errors on one or more devices." "ERROR"
        exit 3
    }
    Write-Log "AudioCodes sync finished without errors."
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 3
}
finally {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    }
}
