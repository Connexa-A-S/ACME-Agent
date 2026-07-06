<#
Replaces the Machine SSL certificate on one or more vCenter Server (VCSA) appliances via
the supported certificate-management REST API (vCenter 7.0 U2+ / 8.x).

Requires OutputFormat = pem (reads cert.crt, cert.key and optional issuer.crt). The
certificate must have the vCenter FQDN in its SAN and chain to a CA vCenter trusts.

NOTE: applying the Machine SSL certificate restarts vCenter services, so expect a short
management-plane outage per appliance. Does not touch ESXi host certificates.

Config: copy vcenter.example.xml to vcenter.xml next to this script.

Exit codes: 0 = OK, 2 = retry (no PEM yet), 3 = fatal / one or more vCenters failed.
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

function Invoke-Vc {
    param([string] $Method, [string] $Url, $Headers, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; TimeoutSec = 180 }
    if ($script:SkipCert) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    if ($null -ne $Body) {
        $p.ContentType = "application/json"
        $p.Body = ($Body | ConvertTo-Json -Depth 6)
    }
    return Invoke-RestMethod @p
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the vCenter hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    $issuerFile = Join-Path $CurrentPath "issuer.crt"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "vcenter.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy vcenter.example.xml to vcenter.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.VCenterCertSync
    $includeChain = Get-XmlBool $settings.IncludeChain $true
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCert = Get-XmlBool $settings.SkipCertificateCheck $true

    $certPem = [IO.File]::ReadAllText($certFile)
    $keyPem  = [IO.File]::ReadAllText($keyFile)
    $rootPem = ""
    if ($includeChain -and (Test-Path -LiteralPath $issuerFile)) { $rootPem = [IO.File]::ReadAllText($issuerFile) }

    foreach ($vc in $settings.VCenters.VCenter) {
        $vcName = [string]$vc.Name
        try {
            $vcHost = [string]$vc.Host
            $pair = "{0}:{1}" -f [string]$vc.Username, [string]$vc.Password
            $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))

            Write-Log "------------------------------------------------------------"
            Write-Log "vCenter: $vcName ($vcHost)"

            $token = Invoke-Vc -Method POST -Url "https://$vcHost/api/session" -Headers @{ Authorization = "Basic $basic" }
            if (-not $token) { throw "Session creation returned no token." }
            $auth = @{ "vmware-api-session-id" = "$token" }

            $spec = @{ cert = $certPem; key = $keyPem }
            if ($rootPem) { $spec.root_cert = $rootPem }

            Write-Log "Applying Machine SSL certificate (vCenter services will restart) ..."
            Invoke-Vc -Method PUT -Url "https://$vcHost/api/vcenter/certificate-management/vcenter/tls" `
                -Headers $auth -Body @{ spec = $spec } | Out-Null

            try { Invoke-Vc -Method DELETE -Url "https://$vcHost/api/session" -Headers $auth | Out-Null } catch { }

            Write-Log "vCenter '$vcName' updated. It may take a few minutes to restart services."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on vCenter '$vcName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next vCenter." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "vCenter sync finished with errors on one or more appliances." "ERROR"
        exit 3
    }
    Write-Log "vCenter sync finished without errors."
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
