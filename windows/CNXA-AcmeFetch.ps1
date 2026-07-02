<#
.SYNOPSIS
  Connexa ACME fetch agent.

.DESCRIPTION
  Checks CNXA ACME Platform for the assigned service certificate. If the
  remote fingerprint has changed, the agent downloads the new certificate to a
  versioned local folder, updates current/, saves state.json, and optionally
  runs one or more hook scripts in a deterministic hook pipeline.

  The script is intentionally deployment-neutral. It does not import into IIS,
  Exchange, RDS, Nginx etc. Hooks handle product-specific deployment.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\ProgramData\Connexa\ACMEAgent\config.json",
    [switch]$Force,
    [switch]$NoHooks
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Write-AgentLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw | ConvertFrom-Json
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    New-DirectoryIfMissing -Path $dir
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}


function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source directory not found: $SourcePath"
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }

    New-DirectoryIfMissing -Path $DestinationPath

    $items = Get-ChildItem -LiteralPath $SourcePath -Force
    if (-not $items -or $items.Count -eq 0) {
        throw "Source directory is empty: $SourcePath"
    }

    foreach ($item in $items) {
        $dest = Join-Path $DestinationPath $item.Name
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
    }

    $copiedItems = Get-ChildItem -LiteralPath $DestinationPath -Force
    if (-not $copiedItems -or $copiedItems.Count -eq 0) {
        throw "Destination directory is empty after copy: $DestinationPath"
    }
}

function Test-CurrentDirectoryValid {
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [Parameter(Mandatory)][string]$Format
    )

    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        return $false
    }

    if ($Format -eq "pfx") {
        return Test-Path -LiteralPath (Join-Path $CurrentPath "certificate.pfx")
    }

    $pemFiles = @("cert.crt", "cert.key")
    foreach ($pemFile in $pemFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $CurrentPath $pemFile))) {
            return $false
        }
    }

    return $true
}

function Repair-CurrentFromState {
    param(
        $State,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$Format
    )

    if (-not $State -or [string]::IsNullOrWhiteSpace([string]$State.service_name) -or [string]::IsNullOrWhiteSpace([string]$State.version_label)) {
        return $false
    }

    $serviceRoot = Join-Path $OutputPath ([string]$State.service_name)
    $versionDir = Join-Path (Join-Path $serviceRoot "versions") ([string]$State.version_label)
    $currentDir = Join-Path $serviceRoot "current"

    if (-not (Test-Path -LiteralPath $versionDir)) {
        return $false
    }

    Copy-DirectoryContents -SourcePath $versionDir -DestinationPath $currentDir
    return (Test-CurrentDirectoryValid -CurrentPath $currentDir -Format $Format)
}



function Get-HookList {
    param(
        $Config,
        [Parameter(Mandatory)][string]$DefaultHooksPath
    )

    $hooks = New-Object System.Collections.Generic.List[string]

    $hooksPath = [string](Get-ConfigValue -Config $Config -Name "HooksPath" -Default $DefaultHooksPath)
    if (-not [string]::IsNullOrWhiteSpace($hooksPath) -and (Test-Path -LiteralPath $hooksPath)) {
        Get-ChildItem -LiteralPath $hooksPath -File -Filter "*.ps1" |
            Sort-Object Name |
            ForEach-Object { $hooks.Add($_.FullName) }
    }

    if ($Config.PSObject.Properties["Hooks"] -and $Config.Hooks) {
        foreach ($hook in $Config.Hooks) {
            $hookPath = [string]$hook
            if (-not [string]::IsNullOrWhiteSpace($hookPath)) {
                $hooks.Add($hookPath)
            }
        }
    }

    return @($hooks | Select-Object -Unique)
}

function Invoke-HookPipeline {
    param(
        [string[]]$Hooks,
        [Parameter(Mandatory)][string]$CurrentDir,
        [Parameter(Mandatory)][string]$VersionDir,
        [Parameter(Mandatory)][string]$MetadataPath,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][string]$LogPath,
        $Info,
        [string]$PreviousFingerprint
    )

    if (-not $Hooks -or $Hooks.Count -eq 0) {
        Write-AgentLog "No hooks configured."
        return
    }

    foreach ($hookPath in $Hooks) {
        if ([string]::IsNullOrWhiteSpace($hookPath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $hookPath)) {
            Write-AgentLog "Hook not found: $hookPath" "WARN"
            continue
        }

        $hookName = [IO.Path]::GetFileNameWithoutExtension($hookPath)
        $hookLog = Join-Path $LogPath ("hook-{0}-{1}.log" -f $hookName, (Get-Date).ToString("yyyyMMdd"))

        Write-AgentLog "Running hook: $hookPath"

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hookPath `
            -CertificatePath $CurrentDir `
            -CurrentPath $CurrentDir `
            -VersionPath $VersionDir `
            -MetadataPath $MetadataPath `
            -Format $Format `
            -ServiceId ([string]$Info.service_id) `
            -ServiceName ([string]$Info.service_name) `
            -CustomerNumber ([string]$Info.customer_number) `
            -Domain ([string]$Info.domain) `
            -Fingerprint ([string]$Info.fingerprint) `
            -PreviousFingerprint ([string]$PreviousFingerprint) *> $hookLog

        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-AgentLog "Hook OK: $hookPath"
            continue
        }

        if ($exitCode -eq 1) {
            Write-AgentLog "Hook returned warning exit code 1: $hookPath. See $hookLog" "WARN"
            continue
        }

        if ($exitCode -eq 2) {
            throw "Hook requested retry with exit code 2: $hookPath. See $hookLog"
        }

        throw "Hook failed with fatal exit code $($exitCode): $hookPath. See $hookLog"
    }
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    $prop = $Config.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        return $prop.Value
    }

    return $Default
}

function Resolve-SecretValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value.ProtectedValue) {
        $secure = ConvertTo-SecureString -String $Value.ProtectedValue
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }

    if ($Value.File) {
        return (Get-Content -LiteralPath $Value.File -Raw -Encoding UTF8).Trim()
    }

    throw "Unsupported secret value format"
}

function Join-Url {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$RelativeUrl
    )

    if ($RelativeUrl -match '^https?://') {
        return $RelativeUrl
    }

    return $BaseUrl.TrimEnd('/') + '/' + $RelativeUrl.TrimStart('/')
}

function Invoke-AcmeApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Headers,
        $Body = $null,
        [string]$OutFile = $null
    )

    $params = @{
        Method      = $Method
        Uri         = $Url
        Headers     = $Headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = 'application/json'
    }

    if ($OutFile) {
        $params.OutFile = $OutFile
    }

    return Invoke-RestMethod @params
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Read-JsonFile -Path $ConfigPath

$apiBaseUrl = [string]$config.ApiBaseUrl
if ([string]::IsNullOrWhiteSpace($apiBaseUrl)) {
    throw "ApiBaseUrl is missing in config"
}

$serviceApiKey = Resolve-SecretValue -Value $config.ServiceApiKey
if ([string]::IsNullOrWhiteSpace($serviceApiKey)) {
    throw "ServiceApiKey is missing in config"
}

$outputFormat = ([string](Get-ConfigValue -Config $config -Name "OutputFormat" -Default "pfx")).ToLowerInvariant()
if ($outputFormat -notin @("pfx", "pem")) {
    throw "OutputFormat must be 'pfx' or 'pem'"
}

$outputPath = [string](Get-ConfigValue -Config $config -Name "OutputPath" -Default "C:\ProgramData\Connexa\ACMEAgent\certs")
$statePath = [string](Get-ConfigValue -Config $config -Name "StatePath" -Default "C:\ProgramData\Connexa\ACMEAgent\state.json")
$logPath = [string](Get-ConfigValue -Config $config -Name "LogPath" -Default "C:\ProgramData\Connexa\ACMEAgent\logs")
$runHooksOnFirstDownload = [bool](Get-ConfigValue -Config $config -Name "RunHooksOnFirstDownload" -Default $true)
$hooksPath = [string](Get-ConfigValue -Config $config -Name "HooksPath" -Default "C:\ProgramData\Connexa\ACMEAgent\hooks")

New-DirectoryIfMissing -Path $outputPath
New-DirectoryIfMissing -Path $logPath
New-DirectoryIfMissing -Path $hooksPath
$script:LogFile = Join-Path $logPath ("agent-{0}.log" -f (Get-Date).ToString("yyyyMMdd"))

$headers = @{
    "X-API-Key" = $serviceApiKey
    "User-Agent" = "CNXA-ACME-PowerShell-Agent/3.1.0"
}

Write-AgentLog "Checking ACME service at $apiBaseUrl"

$agentInfoUrl = Join-Url -BaseUrl $apiBaseUrl -RelativeUrl "/agent/info"
$info = Invoke-AcmeApi -Method GET -Url $agentInfoUrl -Headers $headers

if ($info.status -ne "active") {
    Write-AgentLog "Service is not active. Current status: $($info.status)" "WARN"
    exit 0
}

if ([string]::IsNullOrWhiteSpace([string]$info.fingerprint)) {
    Write-AgentLog "Remote service did not return a fingerprint" "WARN"
    exit 0
}

$state = Read-JsonFile -Path $statePath
$previousFingerprint = if ($state) { [string]$state.fingerprint } else { $null }
$changed = $Force.IsPresent -or ($previousFingerprint -ne [string]$info.fingerprint)

if (-not $changed) {
    $currentOk = $false
    if ($state -and $state.current_path) {
        $currentOk = Test-CurrentDirectoryValid -CurrentPath ([string]$state.current_path) -Format $outputFormat
    }

    if (-not $currentOk) {
        Write-AgentLog "Certificate unchanged, but current/ is missing or incomplete. Attempting local repair from versions/." "WARN"
        $repaired = Repair-CurrentFromState -State $state -OutputPath $outputPath -Format $outputFormat
        if ($repaired) {
            Write-AgentLog "current/ repaired from version: $($state.version_label)"
            $state.last_checked_at = (Get-Date).ToString("o")
            Save-JsonFile -Object $state -Path $statePath
            exit 0
        }

        Write-AgentLog "Local repair failed. Forcing certificate download." "WARN"
        $changed = $true
    }
    else {
        Write-AgentLog "Certificate unchanged. Fingerprint: $($info.fingerprint)"
        $state.last_checked_at = (Get-Date).ToString("o")
        Save-JsonFile -Object $state -Path $statePath
        exit 0
    }
}

$firstDownload = [string]::IsNullOrWhiteSpace($previousFingerprint)
Write-AgentLog "Certificate update detected. Previous='$previousFingerprint' New='$($info.fingerprint)'"

$serviceName = [string]$info.service_name
if ([string]::IsNullOrWhiteSpace($serviceName)) {
    $serviceName = "service-$($info.service_id)"
}

$serviceRoot = Join-Path $outputPath $serviceName
$versionLabel = "fetched-{0}" -f (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$versionDir = Join-Path (Join-Path $serviceRoot "versions") $versionLabel
$currentDir = Join-Path $serviceRoot "current"
$tempDir = Join-Path $serviceRoot "tmp-download"

New-DirectoryIfMissing -Path $versionDir
if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
}
New-DirectoryIfMissing -Path $tempDir

try {
    if ($outputFormat -eq "pfx") {
        $pfxPassword = Resolve-SecretValue -Value $config.PfxPassword
        if ([string]::IsNullOrWhiteSpace($pfxPassword)) {
            throw "PfxPassword is required when OutputFormat is pfx"
        }

        $downloadUrl = Join-Url -BaseUrl $apiBaseUrl -RelativeUrl ([string]$info.download_pfx_url)
        $downloadFile = Join-Path $tempDir "certificate.pfx"
        Invoke-AcmeApi -Method POST -Url $downloadUrl -Headers $headers -Body @{ password = $pfxPassword } -OutFile $downloadFile | Out-Null

        if (-not (Test-Path -LiteralPath $downloadFile) -or ((Get-Item -LiteralPath $downloadFile).Length -le 0)) {
            throw "Downloaded PFX is missing or empty"
        }

        Copy-Item -LiteralPath $downloadFile -Destination (Join-Path $versionDir "certificate.pfx") -Force
    }
    else {
        $downloadUrl = Join-Url -BaseUrl $apiBaseUrl -RelativeUrl ([string]$info.download_pem_url)
        $downloadFile = Join-Path $tempDir "certificate-pem.zip"
        Invoke-AcmeApi -Method GET -Url $downloadUrl -Headers $headers -OutFile $downloadFile | Out-Null

        if (-not (Test-Path -LiteralPath $downloadFile) -or ((Get-Item -LiteralPath $downloadFile).Length -le 0)) {
            throw "Downloaded PEM zip is missing or empty"
        }

        Expand-Archive -LiteralPath $downloadFile -DestinationPath $versionDir -Force
    }

    $metadata = [ordered]@{
        service_id = $info.service_id
        service_name = $info.service_name
        customer_number = $info.customer_number
        domain = $info.domain
        domains = $info.domains
        not_after = $info.not_after
        fingerprint = $info.fingerprint
        previous_fingerprint = $previousFingerprint
        fetched_at = (Get-Date).ToString("o")
        output_format = $outputFormat
        version_label = $versionLabel
    }

    Save-JsonFile -Object $metadata -Path (Join-Path $versionDir "metadata.json")

    Copy-DirectoryContents -SourcePath $versionDir -DestinationPath $currentDir

    if (-not (Test-CurrentDirectoryValid -CurrentPath $currentDir -Format $outputFormat)) {
        throw "Current directory is incomplete after copy: $currentDir"
    }

    $newState = [ordered]@{
        service_id = $info.service_id
        service_name = $info.service_name
        customer_number = $info.customer_number
        domain = $info.domain
        not_after = $info.not_after
        fingerprint = $info.fingerprint
        previous_fingerprint = $previousFingerprint
        version_label = $versionLabel
        current_path = $currentDir
        last_checked_at = (Get-Date).ToString("o")
        last_updated_at = (Get-Date).ToString("o")
    }
    Save-JsonFile -Object $newState -Path $statePath

    Write-AgentLog "Certificate saved to $currentDir"

    $shouldRunHooks = (-not $NoHooks.IsPresent) -and (($firstDownload -and $runHooksOnFirstDownload) -or (-not $firstDownload))
    if ($shouldRunHooks) {
        $hooks = Get-HookList -Config $config -DefaultHooksPath $hooksPath
        Invoke-HookPipeline `
            -Hooks $hooks `
            -CurrentDir $currentDir `
            -VersionDir $versionDir `
            -MetadataPath (Join-Path $currentDir "metadata.json") `
            -Format $outputFormat `
            -LogPath $logPath `
            -Info $info `
            -PreviousFingerprint ([string]$previousFingerprint)
    }


    Write-AgentLog "Done"
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
