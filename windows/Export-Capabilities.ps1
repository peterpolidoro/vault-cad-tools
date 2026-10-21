param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$BaseUri = "http://svault5/AutodeskDM/Services/api/vault/v2/",
    [string]$JobConfig = "C:\Program Files\Autodesk\Vault Client 2025\Explorer\JobProcessor.exe.config"
)
$ErrorActionPreference = "Stop"
$endpoint = [Uri]$BaseUri
if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @("http", "https") -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) {
    throw "BaseUri must be an HTTP(S) URL without credentials, query, or fragment."
}
if (Test-Path -LiteralPath $OutputDirectory) { throw "Choose a new output directory." }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$base = $BaseUri.TrimEnd('/') + '/'
foreach ($name in @("server-info", "vaults", "openapi-spec.yml")) {
    $outputName = if ($name -eq "openapi-spec.yml") { $name } else { $name + ".json" }
    Invoke-WebRequest -Uri ($base + $name) -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 30 -OutFile (Join-Path $OutputDirectory $outputName)
}
if (Test-Path -LiteralPath $JobConfig) {
    $configText = Get-Content -LiteralPath $JobConfig -Raw
    $types = @([regex]::Matches($configText, 'Autodesk\.Vault\.(?:STEP|PDF|DXF|DWF)\.Create\.[A-Za-z0-9]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    ConvertTo-Json -InputObject $types | Set-Content -LiteralPath (Join-Path $OutputDirectory "installed-job-types.json") -Encoding UTF8
}
$files = @(Get-ChildItem -LiteralPath $OutputDirectory -File | ForEach-Object {
    @{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
@{ captured_at = [DateTime]::UtcNow.ToString("o"); base_uri = $base; authenticated = $false; files = $files } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory "capture.json") -Encoding UTF8
Write-Output "Unauthenticated capability capture complete. No Vault changes were made."
