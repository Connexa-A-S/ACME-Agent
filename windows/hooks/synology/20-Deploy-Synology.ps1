<#
Deploys a renewed certificate to one or more Synology DSM devices via the DSM Web API:
logs in, finds the existing certificate by description (to replace it in place), imports
the new key/cert/chain, then logs out.

Requires OutputFormat = pem (reads cert.crt, cert.key and optional issuer.crt).

Targets DSM 7. The Web API and its versions differ between DSM releases — verify against
your device and adjust the api versions if needed.

Config: copy synology.example.xml to synology.xml next to this script.

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

function Invoke-Syno {
    param([string] $Url)
    $p = @{ Method = "GET"; Uri = $Url; TimeoutSec = 60 }
    if ($script:SkipCert) {
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
    }
    return Invoke-RestMethod @p
}

function Add-Text {
    param([System.IO.MemoryStream] $Ms, [string] $Boundary, [string] $Name, [string] $Value)
    $s = "--$Boundary`r`nContent-Disposition: form-data; name=`"$Name`"`r`n`r`n$Value`r`n"
    $b = [Text.Encoding]::UTF8.GetBytes($s)
    $Ms.Write($b, 0, $b.Length)
}

function Add-File {
    param([System.IO.MemoryStream] $Ms, [string] $Boundary, [string] $Name, [string] $FileName, [string] $FilePath)
    $head = "--$Boundary`r`nContent-Disposition: form-data; name=`"$Name`"; filename=`"$FileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
    $hb = [Text.Encoding]::UTF8.GetBytes($head)
    $fb = [IO.File]::ReadAllBytes($FilePath)
    $tail = [Text.Encoding]::UTF8.GetBytes("`r`n")
    $Ms.Write($hb, 0, $hb.Length); $Ms.Write($fb, 0, $fb.Length); $Ms.Write($tail, 0, $tail.Length)
}

try {
    if ($Format -ne "pem") {
        Write-Log "OutputFormat is '$Format'; the Synology hook requires pem. Skipping." "WARN"
        exit 2
    }

    $certFile = Join-Path $CurrentPath "cert.crt"
    $keyFile  = Join-Path $CurrentPath "cert.key"
    $issuerFile = Join-Path $CurrentPath "issuer.crt"
    if (-not (Test-Path -LiteralPath $certFile) -or -not (Test-Path -LiteralPath $keyFile)) {
        Write-Log "cert.crt / cert.key not found in $CurrentPath. Set agent OutputFormat to pem." "ERROR"
        exit 2
    }

    $ConfigPath = Join-Path $PSScriptRoot "synology.xml"
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Log "Config not found: $ConfigPath. Copy synology.example.xml to synology.xml." "ERROR"
        exit 3
    }

    [xml] $config = Get-Content -LiteralPath $ConfigPath
    $settings = $config.SynologyCertSync
    $desc = [string]$settings.Description
    if ([string]::IsNullOrWhiteSpace($desc)) { throw "Description missing in $ConfigPath" }
    $asDefault = if (Get-XmlBool $settings.AsDefault $true) { "true" } else { "false" }
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCert = Get-XmlBool $settings.SkipCertificateCheck $true

    foreach ($dev in $settings.Devices.Device) {
        $devName = [string]$dev.Name
        $sid = $null
        $base = $null
        try {
            $base = "https://$([string]$dev.Host)/webapi"
            $u = [Uri]::EscapeDataString([string]$dev.Username)
            $p = [Uri]::EscapeDataString([string]$dev.Password)

            Write-Log "------------------------------------------------------------"
            Write-Log "Synology: $devName ($([string]$dev.Host))"

            $login = Invoke-Syno "$base/auth.cgi?api=SYNO.API.Auth&version=6&method=login&account=$u&passwd=$p&session=Certificate&format=sid"
            if (-not $login.success) { throw "Login failed: $($login.error.code)" }
            $sid = $login.data.sid

            # Replace in place: find the existing certificate id by description.
            $id = ""
            $list = Invoke-Syno "$base/entry.cgi?api=SYNO.Core.Certificate.CRT&method=list&version=1&_sid=$sid"
            if ($list.success -and $list.data.certificates) {
                $match = $list.data.certificates | Where-Object { $_.desc -eq $desc } | Select-Object -First 1
                if ($match) { $id = $match.id; Write-Log "Replacing existing certificate id=$id (desc '$desc')." }
                else { Write-Log "No existing certificate with desc '$desc'; importing new." }
            }

            $boundary = "----CNXA" + [Guid]::NewGuid().ToString("N")
            $ms = New-Object System.IO.MemoryStream
            Add-File -Ms $ms -Boundary $boundary -Name "key" -FileName "cert.key" -FilePath $keyFile
            Add-File -Ms $ms -Boundary $boundary -Name "cert" -FileName "cert.crt" -FilePath $certFile
            if (Test-Path -LiteralPath $issuerFile) {
                Add-File -Ms $ms -Boundary $boundary -Name "inter_cert" -FileName "issuer.crt" -FilePath $issuerFile
            }
            Add-Text -Ms $ms -Boundary $boundary -Name "id" -Value $id
            Add-Text -Ms $ms -Boundary $boundary -Name "desc" -Value $desc
            Add-Text -Ms $ms -Boundary $boundary -Name "as_default" -Value $asDefault
            $end = [Text.Encoding]::UTF8.GetBytes("--$boundary--`r`n")
            $ms.Write($end, 0, $end.Length)
            $body = $ms.ToArray(); $ms.Dispose()

            $importParams = @{
                Method      = "POST"
                Uri         = "$base/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1&_sid=$sid"
                Body        = $body
                ContentType = "multipart/form-data; boundary=$boundary"
                TimeoutSec  = 120
            }
            if ($script:SkipCert) {
                if ($PSVersionTable.PSVersion.Major -ge 6) { $importParams.SkipCertificateCheck = $true }
                else { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } }
            }
            $result = Invoke-RestMethod @importParams
            if (-not $result.success) { throw "Import failed: error $($result.error.code)" }

            Write-Log "Synology '$devName' done."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Error on Synology '$devName': $($_.Exception.Message)" "ERROR"
            Write-Log "Continuing with next device." "WARN"
        }
        finally {
            if ($sid -and $base) {
                try { Invoke-Syno "$base/auth.cgi?api=SYNO.API.Auth&version=6&method=logout&session=Certificate&_sid=$sid" | Out-Null } catch { }
            }
        }
    }

    Write-Log "------------------------------------------------------------"
    if ($script:HadErrors) {
        Write-Log "Synology sync finished with errors on one or more devices." "ERROR"
        exit 3
    }
    Write-Log "Synology sync finished without errors."
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
