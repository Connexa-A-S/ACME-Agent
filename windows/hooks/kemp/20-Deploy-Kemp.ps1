<#
Deploys a renewed certificate to one or more Kemp LoadMaster appliances via the REST
API (access/addcert). Uploads the combined PEM (private key + certificate + chain) under
a named certificate; with replace=1 an existing certificate of that name is updated in
place, so Virtual Services referencing it keep working.

Requires OutputFormat = pem (reads cert.crt, cert.key and optional issuer.crt).

Config: copy kemp.example.xml to kemp.xml next to this script.

Exit codes: 0 = OK, 2 = retry (no PEM yet), 3 = fatal / one or more LoadMasters failed.
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

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the Kemp hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    $issuerFile = Join-Path $CurrentPath "issuer.crt"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "kemp.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy kemp.example.xml to kemp.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.KempCertSync
    $CertName = [string]$settings.CertName
    if ([string]::IsNullOrWhiteSpace($CertName)) { throw "CertName missing in $ConfigPath" }
    $script:LogPath = [string]$settings.LogPath
    $skipCert = Get-XmlBool $settings.SkipCertificateCheck $true

    # Combined PEM: key + certificate + chain (LoadMaster expects all in one blob).
    $combined = (Get-Content -LiteralPath $keyFile -Raw) + "`n" + (Get-Content -LiteralPath $certFile -Raw)
    if (Test-Path -LiteralPath $issuerFile) { $combined += "`n" + (Get-Content -LiteralPath $issuerFile -Raw) }
    $bodyBytes = [Text.Encoding]::ASCII.GetBytes($combined)

    foreach ($lm in $settings.LoadMasters.LoadMaster) {
        $lmName = [string]$lm.Name
        try {
            $lmHost = [string]$lm.Host
            $pair = "{0}:{1}" -f [string]$lm.Username, [string]$lm.Password
            $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

            Write-Log "------------------------------------------------------------"
            Write-Log "Kemp LoadMaster: $lmName ($lmHost) -> cert '$CertName'"

            $params = @{
                Method      = "POST"
                Uri         = "https://$lmHost/access/addcert?cert=$CertName&replace=1"
                Body        = $bodyBytes
                ContentType = "application/octet-stream"
                Headers     = @{ Authorization = "Basic $auth" }
                TimeoutSec  = 60
            }
            if ($skipCert) {
                if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
                else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
            }

            $resp = Invoke-RestMethod @params
            Write-Log "Upload response: $resp"
            Write-Log "Kemp '$lmName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on Kemp '$lmName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next LoadMaster." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "Kemp sync finished with errors on one or more LoadMasters." "ERROR"
        exit 3
    }
    Write-Log "Kemp sync finished without errors."
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
