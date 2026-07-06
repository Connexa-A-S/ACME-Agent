<#
Shared helpers for the CNXA ACME Windows-role hooks.

This file lives in a _lib subfolder so the agent's hook scanner (which lists *.ps1
non-recursively in HooksPath) never executes it as a hook. Hooks dot-source it:

    . (Join-Path $PSScriptRoot "_lib\Common.ps1")

The agent redirects every hook's output streams to a per-hook log file, so hooks
only need Write-Host (via Write-HookLog) for logging.
#>

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Write-HookLog {
    param(
        [string] $Message,
        [ValidateSet("INFO", "WARN", "ERROR")] [string] $Level = "INFO"
    )
    Write-Host ("{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message)
}

function Get-HookConfig {
    param(
        [Parameter(Mandatory)][string] $HookRoot,
        [string] $FileName = "hooks.json"
    )
    $path = Join-Path $HookRoot $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Hook config not found: $path. Copy hooks.example.json to $FileName and configure it."
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-DeployedThumbprint {
    param(
        [Parameter(Mandatory)][string] $CurrentPath,
        [Parameter(Mandatory)][string] $Thumbprint
    )
    Set-Content -LiteralPath (Join-Path $CurrentPath "deployed-thumbprint.txt") `
        -Value $Thumbprint -Encoding ASCII
}

function Get-DeployedThumbprint {
    <#
      Returns the SHA1 thumbprint of the certificate that 10-import-to-store placed in
      LocalMachine\My during this run. Prefers the hand-off file written by that hook;
      falls back to the newest store certificate whose subject/SAN matches the domain.
    #>
    param(
        [Parameter(Mandatory)][string] $CurrentPath,
        [string] $Domain
    )

    $file = Join-Path $CurrentPath "deployed-thumbprint.txt"
    if (Test-Path -LiteralPath $file) {
        $tp = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($tp) { return $tp }
    }

    if ($Domain) {
        $needle = $Domain.TrimStart('*').TrimStart('.').ToLowerInvariant()
        $match = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
            $names = @($_.Subject)
            try { $names += $_.DnsNameList.Unicode } catch { }
            (($names -join ' ').ToLowerInvariant()).Contains($needle)
        } | Sort-Object NotBefore -Descending | Select-Object -First 1
        if ($match) { return $match.Thumbprint }
    }

    throw "Could not determine the deployed certificate thumbprint. Ensure 10-import-to-store runs before this hook (OutputFormat must be pfx)."
}
