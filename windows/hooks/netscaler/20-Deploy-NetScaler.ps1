<#
Deploys a renewed certificate to one or more Citrix NetScaler / ADC appliances via the
NITRO REST API. Uploads the PEM certificate and key, then hot-updates an existing
sslcertkey in place (nodomaincheck) so bindings on vservers keep working — or adds it
if it does not exist yet.

Requires the agent to use PEM output (OutputFormat = pem): reads cert.crt and cert.key
from the current certificate folder.

Config: copy netscaler.example.xml to netscaler.xml next to this script.

Exit codes: 0 = OK, 2 = retry (no PEM yet), 3 = fatal / one or more appliances failed.
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

function Invoke-Nitro {
    param(
        [ValidateSet("GET","POST","DELETE")] [string] $Method,
        [string] $Path,
        $Body = $null,
        [switch] $AllowNotFound
    )

    $params = @{
        Method     = $Method
        Uri        = "https://$script:NsHost/nitro/v1/config/$Path"
        TimeoutSec = 60
        Headers    = @{ "X-NITRO-USER" = $script:NsUser; "X-NITRO-PASS" = $script:NsPass }
    }
    if ($script:SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw
    }
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the NetScaler hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "netscaler.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy netscaler.example.xml to netscaler.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.NetScalerCertSync

    $CertKeyName = [string]$settings.CertKeyName
    if ([string]::IsNullOrWhiteSpace($CertKeyName)) { throw "CertKeyName missing in $ConfigPath" }
    $FileLocation = if ($settings.FileLocation) { [string]$settings.FileLocation } else { "/nsconfig/ssl" }
    $SaveConfig = Get-XmlBool $settings.SaveConfig $true
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCertificateCheck = Get-XmlBool $settings.SkipCertificateCheck $true

    $certB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($certFile))
    $keyB64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keyFile))
    $certFileName = "$CertKeyName.cer"
    $keyFileName  = "$CertKeyName.key"
    $locEncoded = [Uri]::EscapeDataString($FileLocation)

    foreach ($ns in $settings.NetScalers.NetScaler) {
        $nsName = [string]$ns.Name
        try {
            $script:NsHost = [string]$ns.Host
            $script:NsUser = [string]$ns.Username
            $script:NsPass = [string]$ns.Password

            Write-Log "------------------------------------------------------------"
            Write-Log "NetScaler: $nsName ($script:NsHost)"

            foreach ($f in @(@{ n = $certFileName; c = $certB64 }, @{ n = $keyFileName; c = $keyB64 })) {
                Write-Log "Uploading $($f.n) to $FileLocation ..."
                # Replace any existing file with the same name.
                Invoke-Nitro -Method DELETE -Path "systemfile/$($f.n)?args=filelocation:$locEncoded" -AllowNotFound | Out-Null
                $fileBody = @{ systemfile = @{ filename = $f.n; filecontent = $f.c; filelocation = $FileLocation; fileencoding = "BASE64" } }
                Invoke-Nitro -Method POST -Path "systemfile" -Body $fileBody | Out-Null
            }

            $existing = Invoke-Nitro -Method GET -Path "sslcertkey/$CertKeyName" -AllowNotFound
            if ($existing) {
                Write-Log "sslcertkey '$CertKeyName' exists -> updating in place."
                $body = @{ sslcertkey = @{ certkey = $CertKeyName; cert = $certFileName; key = $keyFileName; nodomaincheck = "true" } }
                Invoke-Nitro -Method POST -Path "sslcertkey?action=update" -Body $body | Out-Null
            }
            else {
                Write-Log "sslcertkey '$CertKeyName' does not exist -> creating."
                $body = @{ sslcertkey = @{ certkey = $CertKeyName; cert = $certFileName; key = $keyFileName } }
                Invoke-Nitro -Method POST -Path "sslcertkey" -Body $body | Out-Null
                Write-Log "Created. Remember to bind '$CertKeyName' to the relevant vservers." "WARN"
            }

            if ($SaveConfig) {
                Write-Log "Saving NetScaler config."
                Invoke-Nitro -Method POST -Path "nsconfig?action=save" -Body @{ nsconfig = @{} } | Out-Null
            }

            Write-Log "NetScaler '$nsName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on NetScaler '$nsName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next appliance." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "NetScaler sync finished with errors on one or more appliances." "ERROR"
        exit 3
    }
    Write-Log "NetScaler sync finished without errors."
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
