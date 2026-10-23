<#
.SYNOPSIS
Put a Windows-integrated Vault Data API session token into $env:VAULT_CAD_TOKEN for this shell.

.DESCRIPTION
Dot-source this script so the variable lands in your interactive shell:

    . .\windows\Set-VaultCadToken.ps1
    pixi run --locked cli --project ..\free-standing-tank-enclosure search 'Free Standing Enclosure.iam'

It calls POST /sessions/win-auth with the current Windows identity (Active Directory account
mapped in Vault), stores the returned access token in the environment of this process only,
and prints the session id and user name but never the token. Nothing is written to disk.
Verified against Vault Professional Server 2025 (30.4) on 2026-10-21.

Vault 2025 answers 501 to DELETE /sessions/{id}; sessions expire server-side.
The default server URL uses HTTP, so the token is not protected by TLS on the network.
#>
param(
    [string]$BaseUri = "http://svault5/AutodeskDM/Services/api/vault/v2/",
    [string]$VaultName = "IDF VAULT",
    [string]$AppCode = "vault-cad-tools"
)
if ($MyInvocation.InvocationName -ne '.') {
    Write-Error "Dot-source this script (. .\windows\Set-VaultCadToken.ps1) so VAULT_CAD_TOKEN stays in your shell."
    return
}
$endpoint = [Uri]$BaseUri
if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @("http", "https") -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) {
    throw "BaseUri must be an HTTP(S) URL without credentials, query, or fragment."
}
# Windows credentials and the returned token must not travel through an ambient HTTP proxy (P4).
[System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy
$body = @{ input = @{ vault = $VaultName; appCode = $AppCode } } | ConvertTo-Json -Depth 3
$session = Invoke-RestMethod -Uri ($BaseUri.TrimEnd('/') + '/sessions/win-auth') -Method Post -ContentType 'application/json' `
    -Body $body -UseDefaultCredentials -MaximumRedirection 0 -TimeoutSec 30
if (-not $session.accessToken) { throw "No access token in the win-auth response." }
$env:VAULT_CAD_TOKEN = $session.accessToken
Write-Host "Vault session $($session.id) for '$($session.userInformation.name)' on vault '$($session.vaultInformation.name)' stored in VAULT_CAD_TOKEN (not displayed)."
