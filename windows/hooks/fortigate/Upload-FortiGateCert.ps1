param(
    [string] $ConfigPath = ".\DKFortigate.xml",
    [Parameter(Mandatory)] [string] $PfxFile,
    [Parameter(Mandatory)] [string] $PfxPass
)

$ErrorActionPreference = "Stop"
$script:HadErrors = $false

# Windows PowerShell 5.1 does not enable TLS 1.2 by default. PowerShell 7 already does.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-Log {
    param(
        [string] $Message,
        [ValidateSet("INFO","WARN","ERROR")] [string] $Level = "INFO"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line

    if ($script:LogPath) {
        $folder = Split-Path $script:LogPath -Parent
        if ($folder -and -not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
        }

        Add-Content -Path $script:LogPath -Value $line
    }
}

function Get-XmlBool {
    param(
        $Value,
        [bool] $Default = $false
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Default
    }

    return [bool]::Parse([string]$Value)
}

function Invoke-FortiGateApi {
    param(
        [ValidateSet("GET","POST","PUT","DELETE")] [string] $Method,
        [string] $Path,
        $Body = $null
    )

    # Authenticate with a Bearer token header rather than an access_token query
    # parameter, so the token never ends up in a URL (logs, proxies, history).
    $params = @{
        Method     = $Method
        Uri        = "https://$script:FortiGateHost$Path"
        TimeoutSec = 60
        Headers    = @{ Authorization = "Bearer $script:ApiToken" }
    }

    # -SkipCertificateCheck only exists in PowerShell 6+. On Windows PowerShell 5.1 we
    # disable validation with a process-wide callback instead (reset in the outer finally).
    if ($script:SkipCertificateCheck) {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params.SkipCertificateCheck = $true
        }
        else {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
    }

    if ($Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    # FortiGate can reset its HTTPS/API listener for a few seconds after a certificate
    # import or admin-server-cert change. Retry idempotent calls so the flow continues
    # instead of leaving references on the fallback certificate.
    $maxAttempts = if ($Method -in @("GET","PUT","DELETE")) { 6 } else { 1 }
    $retryDelays = @(3, 5, 8, 13, 21)

    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod @params
        }
        catch {
            if ($attempt -ge ($maxAttempts - 1)) {
                throw
            }
            $delay = $retryDelays[[Math]::Min($attempt, $retryDelays.Count - 1)]
            Write-Log "FortiGate $Method $Path fejlede (forsøg $($attempt + 1)/$maxAttempts): $($_.Exception.Message). Prøver igen om $delay s." "WARN"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CmdbValue {
    param($Response, [string] $Property)
    if ($null -eq $Response) { return $null }
    $first = @($Response.results)[0]
    if ($null -eq $first) { return $null }
    return [string]$first.$Property
}

function Get-FortiGateAdminCert {
    return Get-CmdbValue (Invoke-FortiGateApi -Method GET -Path "/api/v2/cmdb/system/global") "admin-server-cert"
}

function Get-FortiGateSslVpnCert {
    param([string] $Vdom)
    return Get-CmdbValue (Invoke-FortiGateApi -Method GET -Path "/api/v2/cmdb/vpn.ssl/settings?vdom=$Vdom") "servercert"
}

function Set-FortiGateAdminCert {
    param([string] $Name)
    Invoke-FortiGateApi -Method PUT -Path "/api/v2/cmdb/system/global" -Body @{ "admin-server-cert" = $Name } | Out-Null
}

function Set-FortiGateSslVpnCert {
    param([string] $Name, [string] $Vdom)
    Invoke-FortiGateApi -Method PUT -Path "/api/v2/cmdb/vpn.ssl/settings?vdom=$Vdom" -Body @{ servercert = $Name } | Out-Null
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Configfil findes ikke: $ConfigPath"
    }

    if (-not (Test-Path $PfxFile)) {
        throw "PFX-fil findes ikke: $PfxFile"
    }

    [xml] $config = Get-Content $ConfigPath
    $settings = $config.FortiGateCertSync

    $CertName = [string]$settings.CertName
    $Scope = if ($settings.Scope) { [string]$settings.Scope } else { "vdom" }
    $FallbackCert = if ($settings.FallbackCert) { [string]$settings.FallbackCert } else { "Fortinet_Factory" }
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCertificateCheck = Get-XmlBool $settings.SkipCertificateCheck $true

    if ([string]::IsNullOrWhiteSpace($CertName)) {
        throw "CertName mangler i $ConfigPath"
    }

    Write-Log "Starter FortiGate certifikat sync."
    Write-Log "Config: $ConfigPath"
    Write-Log "PFX-fil: $PfxFile"
    Write-Log "Certifikatnavn på FortiGate: $CertName"
    Write-Log "Fallback-certifikat: $FallbackCert"

    Write-Log "Læser PFX-fil..."
    $pfxBytes = [System.IO.File]::ReadAllBytes($PfxFile)
    $pfxBase64 = [Convert]::ToBase64String($pfxBytes)

    $fortiGates = $settings.FortiGates.FortiGate

    foreach ($fg in $fortiGates) {
        try {
            $fgName = [string]$fg.Name
            $script:FortiGateHost = [string]$fg.Host
            $script:ApiToken = [string]$fg.ApiToken
            $Vdom = if ($fg.Vdom) { [string]$fg.Vdom } else { "root" }

            $UpdateAdminCert = Get-XmlBool $fg.UpdateAdminCert $true
            $UpdateSslVpnCert = Get-XmlBool $fg.UpdateSslVpnCert $true

            Write-Log "------------------------------------------------------------"
            Write-Log "Starter FortiGate: $fgName"
            Write-Log "Host: $script:FortiGateHost"
            Write-Log "VDOM: $Vdom"

            Write-Log "Tester FortiGate API..."
            $status = Invoke-FortiGateApi -Method GET -Path "/api/v2/monitor/system/status"
            Write-Log "Forbundet til FortiGate $($status.version), serial $($status.serial)."

            Write-Log "Henter eksisterende certifikater..."
            $fortiCerts = Invoke-FortiGateApi -Method GET -Path "/api/v2/cmdb/vpn.certificate/local?vdom=$Vdom"
            $existingCert = $fortiCerts.results |
                Where-Object { $_.name -eq $CertName } |
                Select-Object -First 1

            $movedAdmin = $false
            $movedSslVpn = $false

            if ($existingCert) {
                # Safe replace: FortiGate refuses to delete/re-import a certificate that
                # is still referenced. Move known references to an existing fallback
                # certificate first, then delete and re-import under the final name.
                Write-Log "Certifikatet '$CertName' findes. Udfører sikker udskiftning via fallback '$FallbackCert'."

                if ((Get-FortiGateAdminCert) -eq $CertName) {
                    Write-Log "Admin-server-cert peger på '$CertName' -> flytter midlertidigt til '$FallbackCert'."
                    Set-FortiGateAdminCert -Name $FallbackCert
                    $movedAdmin = $true
                }

                if ((Get-FortiGateSslVpnCert -Vdom $Vdom) -eq $CertName) {
                    Write-Log "SSL-VPN servercert peger på '$CertName' -> flytter midlertidigt til '$FallbackCert'."
                    Set-FortiGateSslVpnCert -Name $FallbackCert -Vdom $Vdom
                    $movedSslVpn = $true
                }

                Write-Log "Sletter eksisterende certifikat '$CertName'."
                Invoke-FortiGateApi -Method DELETE -Path "/api/v2/cmdb/vpn.certificate/local/$CertName?vdom=$Vdom" | Out-Null
            }
            else {
                Write-Log "Certifikatet '$CertName' findes ikke. Det oprettes."
            }

            $body = @{
                type         = "pkcs12"
                certname     = $CertName
                password     = $PfxPass
                scope        = $Scope
                file_content = $pfxBase64
            }

            Write-Log "Uploader PFX til FortiGate..."
            $upload = Invoke-FortiGateApi -Method POST -Path "/api/v2/monitor/vpn-certificate/local/import?vdom=$Vdom" -Body $body
            Write-Log "Upload gennemført. Status: $($upload.status)"

            # Point references at the new certificate. Anything we moved to the fallback
            # is always restored, plus anything explicitly requested in config.
            if ($UpdateAdminCert -or $movedAdmin) {
                Write-Log "Sætter HTTPS admin-certifikat til '$CertName'..."
                Set-FortiGateAdminCert -Name $CertName
                Write-Log "HTTPS admin-certifikat opdateret."
            }
            else {
                Write-Log "Springer HTTPS admin-certifikat over."
            }

            if ($UpdateSslVpnCert -or $movedSslVpn) {
                Write-Log "Sætter SSL-VPN certifikat til '$CertName'..."
                Set-FortiGateSslVpnCert -Name $CertName -Vdom $Vdom
                Write-Log "SSL-VPN certifikat opdateret."
            }
            else {
                Write-Log "Springer SSL-VPN certifikat over."
            }

            Write-Log "FortiGate '$fgName' færdig uden fejl."
        }
        catch {
            $script:HadErrors = $true
            Write-Log "Fejl på FortiGate '$fgName': $($_.Exception.Message)" "ERROR"
            Write-Log "Fortsætter med næste FortiGate." "WARN"
        }
    }

    Write-Log "------------------------------------------------------------"

    if ($script:HadErrors) {
        # Fatal exit code (3) so the agent's hook pipeline treats a failed deployment
        # as a real failure instead of a warning that is silently swallowed.
        Write-Log "Certifikat-sync færdig med fejl på en eller flere FortiGates." "ERROR"
        exit 3
    }

    Write-Log "Certifikat-sync færdig uden fejl."
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
