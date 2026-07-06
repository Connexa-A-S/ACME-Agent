<#
Deploys a renewed certificate to one or more Palo Alto (PAN-OS) firewalls via the
XML API: imports the certificate and private key, then commits.

Requires the agent to use PEM output (OutputFormat = pem): reads cert.crt and cert.key.

After import you still need the certificate referenced by an SSL/TLS Service Profile
(GlobalProtect, mgmt, decryption, etc.) — that binding is left to your configuration.
The commit is asynchronous; this hook fires it and returns.

Config: copy paloalto.example.xml to paloalto.xml next to this script.

Exit codes: 0 = OK, 2 = retry (no PEM yet), 3 = fatal / one or more firewalls failed.
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

# Hand-rolled multipart/form-data upload so it works on both Windows PowerShell 5.1
# and PowerShell 7 (5.1 has no -Form). Returns the parsed PAN-OS XML response.
function Invoke-PanImport {
    param([string] $Url, [string] $FilePath, [string] $ApiKey)

    $boundary = "----CNXA" + [Guid]::NewGuid().ToString("N")
    $fileBytes = [IO.File]::ReadAllBytes($FilePath)
    $fileName = [IO.Path]::GetFileName($FilePath)

    $ms = New-Object System.IO.MemoryStream
    $enc = [Text.Encoding]::ASCII
    $header = "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
    $footer = "`r`n--$boundary--`r`n"
    $headerBytes = $enc.GetBytes($header)
    $footerBytes = $enc.GetBytes($footer)
    $ms.Write($headerBytes, 0, $headerBytes.Length)
    $ms.Write($fileBytes, 0, $fileBytes.Length)
    $ms.Write($footerBytes, 0, $footerBytes.Length)
    $body = $ms.ToArray()
    $ms.Dispose()

    $params = @{
        Method      = "POST"
        Uri         = $Url
        Body        = $body
        ContentType = "multipart/form-data; boundary=$boundary"
        Headers     = @{ "X-PAN-KEY" = $ApiKey }
        TimeoutSec  = 120
    }
    if ($script:SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    return [xml](Invoke-RestMethod @params)
}

function Invoke-PanApi {
    param([string] $Url, [string] $ApiKey)
    $params = @{ Method = "POST"; Uri = $Url; Headers = @{ "X-PAN-KEY" = $ApiKey }; TimeoutSec = 120 }
    if ($script:SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    return [xml](Invoke-RestMethod @params)
}

function Assert-PanOk {
    param($Response, [string] $Step)
    $status = $Response.response.status
    if ($status -ne "success") {
        throw "PAN-OS $Step failed: $($Response.OuterXml)"
    }
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the Palo Alto hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "paloalto.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy paloalto.example.xml to paloalto.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.PaloAltoCertSync
    $CertName = [string]$settings.CertName
    if ([string]::IsNullOrWhiteSpace($CertName)) { throw "CertName missing in $ConfigPath" }
    $doCommit = Get-XmlBool $settings.Commit $true
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCertificateCheck = Get-XmlBool $settings.SkipCertificateCheck $true

    foreach ($fw in $settings.Firewalls.Firewall) {
        $fwName = [string]$fw.Name
        try {
            $fwHost = [string]$fw.Host
            $apiKey = [string]$fw.ApiKey
            $keyPass = [string]$fw.KeyPassphrase

            Write-Log "------------------------------------------------------------"
            Write-Log "Palo Alto: $fwName ($fwHost)"

            $certUrl = "https://$fwHost/api/?type=import&category=certificate&certificate-name=$CertName&format=pem"
            Write-Log "Importing certificate '$CertName' ..."
            Assert-PanOk (Invoke-PanImport -Url $certUrl -FilePath $certFile -ApiKey $apiKey) "certificate import"

            $keyUrl = "https://$fwHost/api/?type=import&category=private-key&certificate-name=$CertName&format=pem&passphrase=$([Uri]::EscapeDataString($keyPass))"
            Write-Log "Importing private key ..."
            Assert-PanOk (Invoke-PanImport -Url $keyUrl -FilePath $keyFile -ApiKey $apiKey) "private-key import"

            if ($doCommit) {
                Write-Log "Committing ..."
                $commitUrl = "https://$fwHost/api/?type=commit&cmd=<commit></commit>"
                Assert-PanOk (Invoke-PanApi -Url $commitUrl -ApiKey $apiKey) "commit"
                Write-Log "Commit queued (asynchronous)."
            }

            Write-Log "Palo Alto '$fwName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on Palo Alto '$fwName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next firewall." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "Palo Alto sync finished with errors on one or more firewalls." "ERROR"
        exit 3
    }
    Write-Log "Palo Alto sync finished without errors."
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
