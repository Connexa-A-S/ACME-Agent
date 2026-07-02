param(
    [string] $ConfigPath = ".\DKFortigate.xml",
    [Parameter(Mandatory)] [string] $PfxFile,
    [Parameter(Mandatory)] [string] $PfxPass
)

$ErrorActionPreference = "Stop"
$script:HadErrors = $false

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
        [ValidateSet("GET","POST","PUT")] [string] $Method,
        [string] $Path,
        $Body = $null
    )

    $separator = if ($Path.Contains("?")) { "&" } else { "?" }
    $uri = "https://$script:FortiGateHost$Path$separator" + "access_token=$script:ApiToken"

    $params = @{
        Method     = $Method
        Uri        = $uri
        TimeoutSec = 60
    }

    if ($script:SkipCertificateCheck) {
        $params.SkipCertificateCheck = $true
    }

    if ($Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
    }

    Invoke-RestMethod @params
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
    $script:LogPath = [string]$settings.LogPath
    $script:SkipCertificateCheck = Get-XmlBool $settings.SkipCertificateCheck $true

    Write-Log "Starter FortiGate certifikat sync."
    Write-Log "Config: $ConfigPath"
    Write-Log "PFX-fil: $PfxFile"
    Write-Log "Certifikatnavn på FortiGate: $CertName"

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
            $fortiCerts = Invoke-FortiGateApi `
                -Method GET `
                -Path "/api/v2/cmdb/vpn.certificate/local?vdom=$Vdom"

            $existingCert = $fortiCerts.results |
                Where-Object { $_.name -eq $CertName } |
                Select-Object -First 1

            if ($existingCert) {
                Write-Log "Certifikatet '$CertName' findes allerede. Det overskrives/opdateres."
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
            $upload = Invoke-FortiGateApi `
                -Method POST `
                -Path "/api/v2/monitor/vpn-certificate/local/import?vdom=$Vdom" `
                -Body $body

            Write-Log "Upload gennemført. Status: $($upload.status)"

            if ($UpdateAdminCert) {
                Write-Log "Opdaterer HTTPS admin-certifikat til '$CertName'..."

                $adminUpdate = Invoke-FortiGateApi `
                    -Method PUT `
                    -Path "/api/v2/cmdb/system/global" `
                    -Body @{
                        "admin-server-cert" = $CertName
                    }

                Write-Log "HTTPS admin-certifikat opdateret. Status: $($adminUpdate.status)"
            }
            else {
                Write-Log "Springer HTTPS admin-certifikat over."
            }

            if ($UpdateSslVpnCert) {
                Write-Log "Opdaterer SSL-VPN certifikat til '$CertName'..."

                $sslVpnUpdate = Invoke-FortiGateApi `
                    -Method PUT `
                    -Path "/api/v2/cmdb/vpn.ssl/settings?vdom=$Vdom" `
                    -Body @{
                        servercert = $CertName
                    }

                Write-Log "SSL-VPN certifikat opdateret. Status: $($sslVpnUpdate.status)"
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
        Write-Log "Certifikat-sync færdig med fejl på en eller flere FortiGates." "ERROR"
        exit 1
    }

    Write-Log "Certifikat-sync færdig uden fejl."
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}