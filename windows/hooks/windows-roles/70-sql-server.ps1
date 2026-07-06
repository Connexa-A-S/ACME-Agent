<#
Configures Microsoft SQL Server to use the freshly imported certificate for
encrypted connections: sets the SuperSocketNetLib\Certificate value, best-effort
grants the SQL service account read on the private key, and restarts the service.

Exit codes: 0 = OK/skip, 3 = fatal.
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
. (Join-Path $PSScriptRoot "_lib\Common.ps1")

function Grant-PrivateKeyRead {
    param([string] $Thumbprint, [string] $Account)
    try {
        $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$Thumbprint"
        $keyName = $null
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if ($rsa -and $rsa.Key -and $rsa.Key.UniqueName) { $keyName = $rsa.Key.UniqueName }        # CNG
        elseif ($cert.PrivateKey -and $cert.PrivateKey.CspKeyContainerInfo) { $keyName = $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName } # legacy CSP

        if (-not $keyName) { Write-HookLog "Could not locate private key file; grant read for '$Account' manually." "WARN"; return }

        $candidates = @(
            (Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$keyName"),
            (Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$keyName")
        )
        $keyFile = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $keyFile) { Write-HookLog "Private key file not found for '$Account'; grant read manually." "WARN"; return }

        & icacls $keyFile /grant "${Account}:(R)" | Out-Null
        Write-HookLog "Granted read on private key to '$Account'."
    }
    catch {
        Write-HookLog "Private key ACL grant failed: $($_.Exception.Message). Grant read for '$Account' manually." "WARN"
    }
}

try {
    $config = Get-HookConfig -HookRoot $PSScriptRoot
    $sql = $config.SqlServer
    if (-not $sql -or -not $sql.Enabled) {
        Write-HookLog "SQL Server hook disabled in hooks.json. Skipping."
        exit 0
    }

    $thumb = (Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain).ToLowerInvariant()
    $instance = if ($sql.Instance) { [string]$sql.Instance } else { "MSSQLSERVER" }

    $mapped = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -ErrorAction Stop).$instance
    if (-not $mapped) { throw "SQL instance '$instance' not found in the registry." }

    $superSocket = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$mapped\MSSQLServer\SuperSocketNetLib"
    Write-HookLog "Setting SQL certificate for instance '$instance' ($mapped) to $thumb."
    Set-ItemProperty -Path $superSocket -Name "Certificate" -Value $thumb

    if ($sql.ForceEncryption) {
        Set-ItemProperty -Path $superSocket -Name "ForceEncryption" -Value 1 -Type DWord
        Write-HookLog "ForceEncryption enabled."
    }

    $serviceName = if ($instance -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$instance" }
    $account = (Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue).StartName
    if ($account) { Grant-PrivateKeyRead -Thumbprint $thumb -Account $account }

    if ($sql.RestartService) {
        Write-HookLog "Restarting SQL service '$serviceName' ..."
        Restart-Service -Name $serviceName -Force
        Write-HookLog "SQL service restarted."
    }
    else {
        Write-HookLog "RestartService is false; restart '$serviceName' to apply the new certificate." "WARN"
    }

    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
