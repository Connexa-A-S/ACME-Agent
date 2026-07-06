<#
Deploys a renewed certificate to one or more F5 BIG-IP systems via iControl REST:
uploads the certificate and key, then installs each under a fixed name. Installing
under an existing name updates it in place, so client-ssl profiles that reference that
cert/key pick up the new material (profile binding itself is left to your config).

Requires OutputFormat = pem (reads cert.crt and cert.key).

Config: copy f5.example.xml to f5.xml next to this script.

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

function New-F5Params {
    param([string] $Method, [string] $Url)
    $p = @{ Method = $Method; Uri = $Url; Headers = @{ Authorization = "Basic $script:Auth" }; TimeoutSec = 120 }
    if ($script:SkipCert) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    return $p
}

function Send-F5Upload {
    param([string] $FilePath, [string] $RemoteName)
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    $len = $bytes.Length
    $p = New-F5Params -Method "POST" -Url "https://$script:F5Host/mgmt/shared/file-transfer/uploads/$RemoteName"
    $p.Body = $bytes
    $p.ContentType = "application/octet-stream"
    $p.Headers["Content-Range"] = "0-$($len - 1)/$len"
    Invoke-RestMethod @p | Out-Null
}

function Invoke-F5Json {
    param([string] $Url, $Body)
    $p = New-F5Params -Method "POST" -Url $Url
    $p.ContentType = "application/json"
    $p.Body = ($Body | ConvertTo-Json -Depth 10)
    return Invoke-RestMethod @p
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the F5 hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "f5.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy f5.example.xml to f5.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.F5CertSync
    $CertName = [string]$settings.CertName
    if ([string]::IsNullOrWhiteSpace($CertName)) { throw "CertName missing in $ConfigPath" }
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCert = Get-XmlBool $settings.SkipCertificateCheck $true

    foreach ($dev in $settings.BigIPs.BigIP) {
        $devName = [string]$dev.Name
        try {
            $script:F5Host = [string]$dev.Host
            $pair = "{0}:{1}" -f [string]$dev.Username, [string]$dev.Password
            $script:Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

            Write-Log "------------------------------------------------------------"
            Write-Log "F5 BIG-IP: $devName ($script:F5Host) -> '$CertName'"

            Write-Log "Uploading certificate and key ..."
            Send-F5Upload -FilePath $certFile -RemoteName "$CertName.crt"
            Send-F5Upload -FilePath $keyFile  -RemoteName "$CertName.key"

            Write-Log "Installing certificate ..."
            Invoke-F5Json -Url "https://$script:F5Host/mgmt/tm/sys/crypto/cert" `
                -Body @{ command = "install"; name = "$CertName.crt"; "from-local-file" = "/var/config/rest/downloads/$CertName.crt" } | Out-Null

            Write-Log "Installing key ..."
            Invoke-F5Json -Url "https://$script:F5Host/mgmt/tm/sys/crypto/key" `
                -Body @{ command = "install"; name = "$CertName.key"; "from-local-file" = "/var/config/rest/downloads/$CertName.key" } | Out-Null

            Write-Log "F5 '$devName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on F5 '$devName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next device." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "F5 sync finished with errors on one or more devices." "ERROR"
        exit 3
    }
    Write-Log "F5 sync finished without errors."
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
