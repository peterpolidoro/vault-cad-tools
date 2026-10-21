<#
.SYNOPSIS
Freeze a Vault file version and its exact dependency versions, and mirror them locally for conversion.

.DESCRIPTION
Read-only against Vault (Vault Data API, Windows-integrated session). For a root file-version id:
  1. reads the file-version object and its recursive child associations
     (GET /file-versions/{id}/uses?option[recurse]=true&option[getLatestAssocs]=false), following
     cursorState pagination;
  2. resolves every folder to its full Vault path and writes dependency-inventory.json
     (version id, master id, version number, state, folder, path, size, who references it);
  3. unless -NoDownload, downloads each exact file version into <CacheRoot>\<Vault path without $/>,
     refusing all existing destination files (use a fresh CacheRoot), and writes acquisition.json with SHA-256 per file.
The mirror root stands in for Vault's "$" so Inventor resolves relative references unchanged.
Never checks files out, never writes to Vault. The token stays in memory and is not printed.
Verified against Vault Professional Server 2025 (30.4) on 2026-10-21; DELETE /sessions returns 501 there.
#>
param(
    [Parameter(Mandatory = $true)][string]$RootVersionId,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$CacheRoot,
    [string]$BaseUri = "http://svault5/AutodeskDM/Services/api/vault/v2/",
    [string]$VaultName = "IDF VAULT",
    [string]$VaultId = "28",
    [string]$AppCode = "vault-cad-tools",
    [switch]$NoDownload
)
$ErrorActionPreference = "Stop"
$endpoint = [Uri]$BaseUri
if (-not $endpoint.IsAbsoluteUri -or $endpoint.Scheme -notin @("http", "https") -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) { throw "BaseUri must be an HTTP(S) URL without credentials, query, or fragment." }
if (-not $NoDownload -and -not $CacheRoot) { throw "Supply -CacheRoot or -NoDownload" }
$B = $BaseUri.TrimEnd('/')
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
function Utc { [DateTime]::UtcNow.ToString("o") }

$body = @{ input = @{ vault = $VaultName; appCode = $AppCode } } | ConvertTo-Json -Depth 3
$session = Invoke-RestMethod -Uri "$B/sessions/win-auth" -Method Post -ContentType "application/json" -Body $body -UseDefaultCredentials -MaximumRedirection 0 -TimeoutSec 30
if (-not $session.accessToken) { throw "win-auth returned no access token" }
$h = @{ Authorization = "Bearer $($session.accessToken)" }
Write-Output "Session $($session.id) as '$($session.userInformation.name)' on vault '$($session.vaultInformation.name)' (id $($session.vaultInformation.id))"
if ([string]$session.vaultInformation.id -ne $VaultId) { throw "Signed into vault id $($session.vaultInformation.id), expected $VaultId" }
function GetJ($rel) { Invoke-RestMethod -Uri "$B/$rel" -Headers $h -MaximumRedirection 0 -TimeoutSec 120 }
function GetAll($rel) {
    $all = @(); $cursor = $null; $pages = 0
    do {
        $url = $rel; if ($cursor) { $url += "&cursorState=" + [uri]::EscapeDataString($cursor) }
        $r = GetJ $url; $pages++
        $all += @($r.results)
        $cursor = $r.pagination.cursorState
    } while ($cursor)
    return @{ results = $all; pages = $pages; total = $r.pagination.totalResults }
}

$root = GetJ "vaults/$VaultId/file-versions/$RootVersionId"
$root | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "file-version-$RootVersionId.json") -Encoding UTF8
$uses = GetAll "vaults/$VaultId/file-versions/$RootVersionId/uses?option%5Brecurse%5D=true&option%5BgetLatestAssocs%5D=false&limit=500"
$uses.results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "uses-$RootVersionId-recurse.json") -Encoding UTF8
Write-Output "Root $($root.name) v$($root.version) ($($root.state)); associations: $($uses.results.Count) over $($uses.pages) page(s), server total $($uses.total)"
if ($uses.total -and ($uses.results.Count -ne $uses.total)) { throw "Association paging incomplete: $($uses.results.Count) of $($uses.total)" }

$folderIds = @([string]$root.parentFolderId) + @($uses.results | ForEach-Object { [string]$_.childFile.parentFolderId }) | Sort-Object -Unique
$folders = [ordered]@{}
foreach ($fid in $folderIds) { $f = GetJ "vaults/$VaultId/folders/$fid"; $folders[$fid] = $f.fullName; Write-Output "folder $fid = $($f.fullName)$(if ($f.isLibrary) { ' (library)' })" }
function Record($v, $role) {
    [ordered]@{ version_id = [string]$v.id; master_id = [string]$v.file.id; name = $v.name; version = $v.version; revision = $v.revision; state = $v.state
        folder_id = [string]$v.parentFolderId; vault_path = "$($folders[[string]$v.parentFolderId])/$($v.name)"; size = $v.size
        checkin_date = $v.checkinDate; is_checked_out = $v.isCheckedOut; role = $role; parents = @() }
}
$files = [ordered]@{}
$files[[string]$root.id] = Record $root "root"
foreach ($a in $uses.results) {
    $c = $a.childFile
    if (-not $files.Contains([string]$c.id)) { $files[[string]$c.id] = Record $c $a.fileAssocType }
    $files[[string]$c.id].parents += "$($a.parentFile.name)@$($a.parentFile.id)"
}
$list = @($files.Values | Sort-Object { $_.vault_path })
$dupNames = @($list | Group-Object name | Where-Object Count -gt 1 | ForEach-Object Name)
$checkedOut = @($list | Where-Object is_checked_out | ForEach-Object name)
$inventory = [ordered]@{ captured_at = Utc; base_uri = "$B/"; vault_id = $VaultId; vault_name = $VaultName; root = $files[[string]$root.id]
    association_count = $uses.results.Count; association_total = $uses.total; association_types = @($uses.results | Group-Object fileAssocType | ForEach-Object { "$($_.Name)=$($_.Count)" })
    folders = $folders; duplicate_names = $dupNames; checked_out = $checkedOut; files = $list }
$inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "dependency-inventory.json") -Encoding UTF8
Write-Output "Inventory: $($list.Count) unique files (incl. root), duplicate names: $(if ($dupNames) { $dupNames -join ', ' } else { 'none' }), checked out: $(if ($checkedOut) { $checkedOut -join ', ' } else { 'none' })"

if ($NoDownload) { Write-Output "Download skipped (-NoDownload)."; return }
$acq = @(); $problems = 0
foreach ($f in $list) {
    $rel = $f.vault_path.Substring(2) -replace '/', '\'
    $dst = Join-Path $CacheRoot $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath $dst) | Out-Null
    if (Test-Path -LiteralPath $dst) {
        # Equal size does not identify a Vault version. Until reuse is checked
        # against trusted version/checksum evidence, require a fresh mirror.
        Write-Output "CONFLICT existing file is not verified for version $($f.version_id): $rel. Use a fresh CacheRoot."
        $problems++
        continue
    }
    $tmp = "$dst.vault-cad-download"
    try {
        Invoke-WebRequest -Uri "$B/vaults/$VaultId/file-versions/$($f.version_id)/content" -Headers $h -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 600 -OutFile $tmp
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -ne $f.size) { throw "size $len differs from Vault size $($f.size)" }
        Move-Item -LiteralPath $tmp -Destination $dst
        $sha = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        $acq += [ordered]@{ version_id = $f.version_id; master_id = $f.master_id; vault_path = $f.vault_path; local_path = $dst; bytes = $len; expected_bytes = $f.size; size_match = $true; sha256 = $sha; reused_existing = $false }
        Write-Output "OK   $($f.version_id) $rel ($len bytes, sha256 $($sha.Substring(0,12)))"
    } catch {
        $problems++; Write-Output "FAIL $($f.version_id) $rel : $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
[ordered]@{ acquired_at = Utc; method = "Vault Data API GET /vaults/$VaultId/file-versions/{id}/content, Windows-integrated session"; cache_root = (Resolve-Path -LiteralPath $CacheRoot).Path; problems = $problems; files = $acq } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "acquisition.json") -Encoding UTF8
Write-Output "Acquisition: $($acq.Count) files recorded, $problems problem(s); acquisition.json written"
if ($problems -gt 0) { exit 1 }
