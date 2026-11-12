<#
.SYNOPSIS
Pure helpers for the exporter's package (the draft specification mechanical-cad/docs/exporter-package.md):
deterministic JSON, directory names, the Vault block, and the validation and comparison of written packages.
No Inventor, no Vault, no network. Dot-source from a script in the same folder:

    . (Join-Path $PSScriptRoot "Package-Format.ps1")

.DESCRIPTION
ConvertTo-PackageJson VALUE          JSON text as the layout writes it: two spaces, LF, a list of scalars on one
                                     line, keys in the order given, a double written so that reading it back
                                     gives the same double (and with a decimal point, so it stays a double).
                                     Only null, strings, booleans, numbers, dictionaries, lists and custom
                                     objects are accepted; anything else (a COM object, a date) is an error.
Write-PackageJsonFile PATH VALUE     the same as a file: UTF-8 without a byte-order mark, a trailing newline;
                                     never overwrites.
Get-PackageStateName, Get-PackageDirectoryName    "[Primary]" -> "primary"; "<master id>_<state>".
New-PackageVaultBlock                the nine vault fields of source.json from one acquisition record and one
                                     dependency-inventory record of the same version.
Test-PackageOutputs -Directory DIR   checks a written package against itself: the manifest and every file's
                                     hash, the fields of source.json and assembly.json, each part.step (normalised
                                     header, protocol, unit, the form of INVISIBILITY), occurrences.json against
                                     the assemblies' definitions, and that no file holds a forbidden text.
Find-PackageForbiddenText            workstation paths, host and account names, and names given by the caller.
Get-PackageFileMap DIR               every file under a directory by its relative path, in ordinal order.
Compare-PackageRuns -First A -Second B    which files of two packages are byte-identical.
Complete-Package -Directory DIR -Manifest M    checks the package, writes package.json last and checks again;
                                     whatever fails after package.json was written removes it.
Remove-PackageManifest DIR, Test-PackageRunStatus STATUS    a package is complete only after a run that ended
                                     "complete"; anything else takes package.json away.
Get-PackageDirectoryHashes DIR, Compare-PackageDirectoryHashes BEFORE AFTER    every file of a directory, and what
                                     changed, appeared or disappeared between two listings.
Guard queries (for the scripts that drive Inventor; nothing here touches it):
Get-RequiredValue WHAT { query } -Kind bool|string|int|number    the value or an exception. The query returns what
                                     the API returned and holds no cast: [int]$null is 0, [bool]$null is False,
                                     [string]$null is "", and a cast would pass "nothing" as a value.
Assert-RequiredObject WHAT OBJECT, Get-RequiredCount WHAT COLLECTION    a collection must exist before it is
                                     counted or walked: $null.Count is 0 and foreach over $null runs zero times.
Get-OptionalValue { query } TYPE, Get-OptionalObject { query }    $null when the API gives nothing or the read fails.
New-PackageGuardLedger NAMES, Add-PackageGuardCheck LEDGER NAME    how often each guard was evaluated in a run.
Offline tests: Test-PackageFormat.ps1.
#>
. (Join-Path $PSScriptRoot "Step-Header.ps1")
. (Join-Path $PSScriptRoot "Step-Units.ps1")

$PackageSchemaVersion = 2
$PackageKind = "vault-cad-export-package"
$PackageLayoutSchemaVersion = 1
$PackageOccurrencesSchemaVersion = 1
$PackageVaultFields = @("vault_id", "master_id", "version_id", "version_number", "revision", "lifecycle_state", "checkin_date", "path", "native_sha256")
$PackageStepFields = @("sha256", "data_sha256", "bytes", "protocol", "length_unit", "header_normalised", "received_sha256")
$PackagePropertyNames = @("category", "description", "manufacturer", "material", "part_number", "stock_number", "title", "vendor")
$PackageChildFlags = @("visible", "suppressed", "grounded", "flexible", "mirrored")
$PackageBomStructures = @("Normal", "Phantom", "Reference", "Purchased", "Inseparable", "Default")
$PackageTranslatorOptions = @("IncludeSketches", "ApplicationProtocolType", "Author", "Organization", "Authorization", "Description", "export_fit_tolerance", "ExportUCS")
$PackageInvariant = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------------------------------------
function Test-PackageScalar($Value) {
    return ($null -eq $Value -or $Value -is [string] -or $Value -is [char] -or $Value -is [bool] -or (Test-PackageNumber $Value))
}
function Test-PackageNumber($Value) {
    return ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal] -or $Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64])
}
function Format-PackageNumber($Number) {
    if ($Number -is [double] -or $Number -is [single]) {
        $real = [double]$Number
        if ([double]::IsNaN($real) -or [double]::IsInfinity($real)) { throw "Package JSON: a number is not finite" }
        $text = $real.ToString("R", $PackageInvariant)
        # "R" does not round-trip every double on the .NET Framework; 17 significant digits always do.
        if ([double]::Parse($text, [Globalization.NumberStyles]::Float, $PackageInvariant) -ne $real) { $text = $real.ToString("G17", $PackageInvariant) }
        if ($text -notmatch '[.eE]') { $text += ".0" }
        return $text
    }
    if ($Number -is [decimal]) { return ([decimal]$Number).ToString($PackageInvariant) }
    return ([Convert]::ToInt64($Number)).ToString($PackageInvariant)
}
function Format-PackageString([string]$Text) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        if ($code -eq 34) { [void]$builder.Append('\"') }
        elseif ($code -eq 92) { [void]$builder.Append('\\') }
        elseif ($code -eq 8) { [void]$builder.Append('\b') }
        elseif ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 12) { [void]$builder.Append('\f') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
        else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}
function Add-PackageJson($Builder, $Value, [int]$Level) {
    # Appends the JSON of one value. Called as a statement: it returns nothing.
    $pad = "  " * $Level; $inner = "  " * ($Level + 1)
    if ($null -eq $Value) { [void]$Builder.Append("null"); return }
    if ($Value -is [string] -or $Value -is [char]) { [void]$Builder.Append((Format-PackageString ([string]$Value))); return }
    if ($Value -is [bool]) { [void]$Builder.Append($(if ($Value) { "true" } else { "false" })); return }
    if (Test-PackageNumber $Value) { [void]$Builder.Append((Format-PackageNumber $Value)); return }
    $pairs = $null
    if ($Value -is [System.Collections.IDictionary]) { $pairs = @(foreach ($key in $Value.Keys) { if ($key -isnot [string]) { throw "Package JSON: a key is not a string ($key)" }; ,@($key, $Value[$key]) }) }
    elseif ($Value.GetType().Name -eq "PSCustomObject") { $pairs = @(foreach ($property in $Value.PSObject.Properties) { ,@($property.Name, $property.Value) }) }
    if ($null -ne $pairs) {
        if ($pairs.Count -eq 0) { [void]$Builder.Append("{}"); return }
        [void]$Builder.Append("{`n")
        for ($index = 0; $index -lt $pairs.Count; $index++) {
            [void]$Builder.Append($inner + (Format-PackageString ([string]$pairs[$index][0])) + ": ")
            Add-PackageJson $Builder $pairs[$index][1] ($Level + 1)
            [void]$Builder.Append($(if ($index -lt $pairs.Count - 1) { ",`n" } else { "`n" }))
        }
        [void]$Builder.Append($pad + "}"); return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($item in $Value) { ,(,$item) })   # each item in an array of its own, so that an item that is a list stays one item
        if ($items.Count -eq 0) { [void]$Builder.Append("[]"); return }
        $allScalar = $true; foreach ($wrapped in $items) { if (-not (Test-PackageScalar $wrapped[0])) { $allScalar = $false; break } }
        if ($allScalar) {
            [void]$Builder.Append("[")
            for ($index = 0; $index -lt $items.Count; $index++) { if ($index -gt 0) { [void]$Builder.Append(", ") }; Add-PackageJson $Builder $items[$index][0] 0 }
            [void]$Builder.Append("]"); return
        }
        [void]$Builder.Append("[`n")
        for ($index = 0; $index -lt $items.Count; $index++) {
            [void]$Builder.Append($inner)
            Add-PackageJson $Builder $items[$index][0] ($Level + 1)
            [void]$Builder.Append($(if ($index -lt $items.Count - 1) { ",`n" } else { "`n" }))
        }
        [void]$Builder.Append($pad + "]"); return
    }
    throw "Package JSON: a value of type $($Value.GetType().FullName) cannot be written"
}
function ConvertTo-PackageJson($Value) {
    $builder = New-Object Text.StringBuilder
    Add-PackageJson $builder $Value 0
    return $builder.ToString()
}
function Write-PackageJsonFile([string]$Path, $Value) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite $Path" }
    $encoding = New-Object Text.UTF8Encoding($false, $true)   # no byte-order mark; an invalid character is an error
    [IO.File]::WriteAllBytes($Path, $encoding.GetBytes((ConvertTo-PackageJson $Value) + "`n"))
}
function Read-PackageJsonFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path); $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    return ((New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset) | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------------------------------------
# Names and the Vault block
# ---------------------------------------------------------------------------------------------------------
function Get-PackageStateName([string]$ModelState) {
    # The model state in lower case, every run of characters other than a-z and 0-9 as one hyphen, none at either end.
    if (-not $ModelState) { return "" }
    return ([regex]::Replace($ModelState.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
}
function Get-PackageDirectoryName([string]$MasterId, [string]$ModelState) {
    if ($MasterId -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { throw "A master id '$MasterId' cannot name a directory" }
    return "$MasterId`_$(Get-PackageStateName $ModelState)"
}
function New-PackageVaultBlock {
    <# The nine vault fields of source.json. Both records describe one file version: the acquisition record gives
       the hash of the downloaded file, the dependency-inventory record the facts Vault returned when the versions
       were frozen. A fact a record does not carry is written as null; nothing is asked of Vault here. #>
    param([Parameter(Mandatory = $true)][string]$VaultId, [Parameter(Mandatory = $true)]$AcquisitionRecord, [Parameter(Mandatory = $true)]$InventoryRecord)
    $master = [string]$AcquisitionRecord.master_id; $version = [string]$AcquisitionRecord.version_id
    if (-not $VaultId -or -not $master -or -not $version) { throw "A vault id, master id or version id is missing" }
    if ([string]$InventoryRecord.master_id -ne $master -or [string]$InventoryRecord.version_id -ne $version -or [string]$InventoryRecord.vault_path -ne [string]$AcquisitionRecord.vault_path) { throw "The acquisition and inventory records of version $version disagree" }
    $hash = ([string]$AcquisitionRecord.sha256).ToLowerInvariant()
    if ($hash -notmatch '^[a-f0-9]{64}$') { throw "The acquisition record of version $version has no SHA-256" }
    $number = $InventoryRecord.version
    $text = { param($value) if ($null -eq $value) { $null } elseif ($value -is [DateTime]) { $value.ToUniversalTime().ToString("o", $PackageInvariant) } else { [string]$value } }
    return [ordered]@{ vault_id = $VaultId; master_id = $master; version_id = $version
        version_number = $(if ($number -is [int] -or $number -is [long]) { [int]$number } else { $null })
        revision = (& $text $InventoryRecord.revision); lifecycle_state = (& $text $InventoryRecord.state); checkin_date = (& $text $InventoryRecord.checkin_date)
        path = [string]$AcquisitionRecord.vault_path; native_sha256 = $hash }
}

# ---------------------------------------------------------------------------------------------------------
# Matrices (4 by 4, row-major, as nested lists in the files; flat arrays of 16 doubles here)
# ---------------------------------------------------------------------------------------------------------
function Get-PackageFlat($Matrix) {
    # A 4 by 4 list of numbers as a flat array, or $null when it is not one.
    if ($null -eq $Matrix -or @($Matrix).Count -ne 4) { return $null }
    $flat = New-Object double[] 16
    for ($row = 0; $row -lt 4; $row++) {
        $cells = @($Matrix[$row]); if ($cells.Count -ne 4) { return $null }
        for ($column = 0; $column -lt 4; $column++) { if (-not (Test-PackageNumber $cells[$column])) { return $null }; $flat[4 * $row + $column] = [double]$cells[$column] }
    }
    return ,$flat
}
function Get-PackageFlatProduct([double[]]$Left, [double[]]$Right) {
    $out = New-Object double[] 16
    for ($row = 0; $row -lt 4; $row++) { for ($column = 0; $column -lt 4; $column++) { $sum = 0.0; for ($k = 0; $k -lt 4; $k++) { $sum += $Left[4 * $row + $k] * $Right[4 * $k + $column] }; $out[4 * $row + $column] = $sum } }
    return ,$out
}
function Get-PackageFlatDeviation([double[]]$Left, [double[]]$Right) {
    # The largest difference of a rotation cell and of a translation cell.
    $rotation = 0.0; $length = 0.0
    for ($row = 0; $row -lt 3; $row++) { for ($column = 0; $column -lt 3; $column++) { $rotation = [Math]::Max($rotation, [Math]::Abs($Left[4 * $row + $column] - $Right[4 * $row + $column])) }; $length = [Math]::Max($length, [Math]::Abs($Left[4 * $row + 3] - $Right[4 * $row + 3])) }
    return [pscustomobject]@{ rotation = $rotation; length = $length }
}
function Test-PackageRigid([double[]]$Flat, [double]$Tolerance = 1e-9) {
    # $null when the matrix is a rotation and a translation; otherwise what is wrong with it.
    if ([Math]::Abs($Flat[12]) -gt 0 -or [Math]::Abs($Flat[13]) -gt 0 -or [Math]::Abs($Flat[14]) -gt 0 -or $Flat[15] -ne 1.0) { return "the last row is not 0 0 0 1" }
    for ($first = 0; $first -lt 3; $first++) { for ($second = $first; $second -lt 3; $second++) {
            $dot = $Flat[$first] * $Flat[$second] + $Flat[4 + $first] * $Flat[4 + $second] + $Flat[8 + $first] * $Flat[8 + $second]
            if ([Math]::Abs($dot - $(if ($first -eq $second) { 1.0 } else { 0.0 })) -gt $Tolerance) { return "the rotation is not orthonormal" } } }
    $determinant = $Flat[0] * ($Flat[5] * $Flat[10] - $Flat[6] * $Flat[9]) - $Flat[1] * ($Flat[4] * $Flat[10] - $Flat[6] * $Flat[8]) + $Flat[2] * ($Flat[4] * $Flat[9] - $Flat[5] * $Flat[8])
    if ($determinant -lt 0) { return "the placement is mirrored (determinant $determinant)" }
    return $null
}

# ---------------------------------------------------------------------------------------------------------
# Files of a directory
# ---------------------------------------------------------------------------------------------------------
function Add-PackageFiles($Folder, [string]$Prefix, $Map) {
    # Called as a statement: files the entries of one folder under their names and goes into its sub-folders.
    foreach ($entry in (Get-ChildItem -LiteralPath $Folder.FullName -Force)) {
        if ($entry.PSIsContainer) { Add-PackageFiles $entry ($Prefix + $entry.Name + "/") $Map } else { $Map[$Prefix + $entry.Name] = $entry.FullName }
    }
}
function Get-PackageFileMap([string]$Directory) {
    <# Every file under a directory: its path relative to the directory, with forward slashes, and its full path,
       in ordinal order of the relative paths. The names are built from the entries, not cut out of full paths: a
       directory given in its 8.3 form lists its files under their long names. #>
    $found = @{}
    Add-PackageFiles (Get-Item -LiteralPath $Directory) "" $found
    [string[]]$names = @($found.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $map = [ordered]@{}
    foreach ($name in $names) { $map[$name] = $found[$name] }
    return $map
}

# ---------------------------------------------------------------------------------------------------------
# Forbidden text
# ---------------------------------------------------------------------------------------------------------
function Find-PackageForbiddenText {
    <# Looks in every file under -Directory for a workstation path (a drive letter or a share, in the JSON files),
       and for each of -Terms as a whole word, whatever its case. Returns one text per hit. A term is searched as it
       is and as JSON writes it (backslashes doubled). #>
    param([Parameter(Mandatory = $true)][string]$Directory, [string[]]$Terms = @())
    $latin1 = [Text.Encoding]::GetEncoding(28591); $hits = @()
    $files = Get-PackageFileMap $Directory
    $patterns = @()
    foreach ($term in @($Terms | Where-Object { $_ } | Sort-Object -Unique)) {
        foreach ($form in @($term, $term.Replace('\', '\\')) | Sort-Object -Unique) {
            $pattern = [regex]::Escape($form)
            if ($form -match '^[A-Za-z0-9]') { $pattern = '(?<![A-Za-z0-9])' + $pattern }
            if ($form -match '[A-Za-z0-9]$') { $pattern = $pattern + '(?![A-Za-z0-9])' }
            $patterns += [pscustomobject]@{ term = $term; regex = (New-Object System.Text.RegularExpressions.Regex -ArgumentList $pattern, ([Text.RegularExpressions.RegexOptions]::IgnoreCase)) }
        }
    }
    foreach ($relative in $files.Keys) {
        $content = $latin1.GetString([IO.File]::ReadAllBytes($files[$relative]))
        foreach ($entry in $patterns) { if ($entry.regex.IsMatch($content)) { $hits += "$relative holds '$($entry.term)'" } }
        if ($relative.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase)) {
            if ($content -match '(?<![A-Za-z0-9])[A-Za-z]:\\\\') { $hits += "$relative holds a path with a drive letter" }
            if ($content -match '(?<!\\)\\\\\\\\[A-Za-z0-9]') { $hits += "$relative holds a path on a share" }
        }
    }
    return @($hits | Sort-Object -Unique)   # bare: callers wrap with @(...)
}

# ---------------------------------------------------------------------------------------------------------
# Validation of a written package
# ---------------------------------------------------------------------------------------------------------
function Test-PackageHas($Object, [string]$Name) { return ($null -ne $Object -and $Object.GetType().Name -eq "PSCustomObject" -and @($Object.PSObject.Properties.Name) -contains $Name) }
function Test-PackageSameNames($Have, $Want) { return ((@($Have | Sort-Object) -join "|") -ceq (@($Want | Sort-Object) -join "|")) }
function Get-PackageSha([byte[]]$Bytes) { $hasher = [Security.Cryptography.SHA256]::Create(); try { return ([BitConverter]::ToString($hasher.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() } finally { $hasher.Dispose() } }

function Test-PackageOutputs {
    <# Checks the package in -Directory against itself. Returns ok, failures (texts) and a summary. With
       -AllowMissingManifest the files are checked before package.json exists (the exporter writes it last). #>
    param([Parameter(Mandatory = $true)][string]$Directory, [string[]]$ForbiddenTerms = @(), [switch]$AllowMissingManifest, [double]$RotationTolerance = 1e-9, [double]$LengthTolerance = 1e-7)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $summary = [ordered]@{ parts = 0; assemblies = 0; children = 0; occurrences = 0; occurrences_that_differ_from_definition = 0; files = 0 }
    $present = Get-PackageFileMap $Directory
    # ---- the manifest ----
    $manifest = $null
    if ($present.Contains("package.json")) {
        try { $manifest = Read-PackageJsonFile $present["package.json"] } catch { $failures.Add("package.json cannot be read: $($_.Exception.Message)") }
    } elseif (-not $AllowMissingManifest) { $failures.Add("package.json is missing: the package is not complete") }
    if ($manifest) {
        if ($manifest.schema_version -ne $PackageSchemaVersion -or $manifest.kind -ne $PackageKind) { $failures.Add("package.json is not a $PackageKind of schema $PackageSchemaVersion") }
        foreach ($field in @("exported_at", "exporter", "translator_options", "vault_id", "root", "acquisition", "counts", "not_exported", "files")) { if (-not (Test-PackageHas $manifest $field)) { $failures.Add("package.json has no $field") } }
        if ((Test-PackageHas $manifest "exporter") -and -not ((Test-PackageHas $manifest.exporter "name") -and (Test-PackageHas $manifest.exporter "version") -and (Test-PackageHas $manifest.exporter "inventor"))) { $failures.Add("package.json exporter must have name, version and inventor") }
        if (Test-PackageHas $manifest "translator_options") {
            foreach ($option in $PackageTranslatorOptions) { if (-not (Test-PackageHas $manifest.translator_options $option)) { $failures.Add("package.json translator_options has no $option") } }
            if ($manifest.translator_options.ApplicationProtocolType -ne 5) { $failures.Add("package.json translator_options: ApplicationProtocolType is not 5 (AP242)") }
            if ($manifest.translator_options.IncludeSketches -ne $false) { $failures.Add("package.json translator_options: IncludeSketches is not false") }
            foreach ($option in @("Author", "Organization", "Authorization", "Description")) { if ((Test-PackageHas $manifest.translator_options $option) -and $manifest.translator_options.$option -ne "") { $failures.Add("package.json translator_options: $option is not empty") } }
        }
        if ((Test-PackageHas $manifest "not_exported") -and $null -eq $manifest.not_exported) { $failures.Add("package.json not_exported must be a list (empty when nothing was left out)") }
        if ((Test-PackageHas $manifest "acquisition") -and -not ((Test-PackageHas $manifest.acquisition "captured_at") -and (Test-PackageHas $manifest.acquisition "method"))) { $failures.Add("package.json acquisition must have captured_at and method") }
        if ($manifest.vault_id -isnot [string] -or -not $manifest.vault_id) { $failures.Add("package.json does not name the vault") }
        if (Test-PackageHas $manifest "files") {
            $listed = @($manifest.files.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($name in $listed) {
                if (-not $present.Contains($name)) { $failures.Add("$name is listed in package.json and missing"); continue }
                $bytes = [IO.File]::ReadAllBytes($present[$name])
                if ((Get-PackageSha $bytes) -ne $manifest.files.$name.sha256 -or $bytes.Length -ne $manifest.files.$name.bytes) { $failures.Add("$name does not match package.json") }
            }
            foreach ($name in $present.Keys) { if ($name -ne "package.json" -and $listed -notcontains $name) { $failures.Add("$name is in the package and not listed in package.json") } }
        }
    }
    # ---- the directories ----
    $documents = @{}   # "master|state" -> record
    foreach ($name in $present.Keys) {
        if ($name -eq "package.json" -or $name -eq "occurrences.json") { continue }
        if ($name -notmatch '^files/[^/]+/(source\.json|part\.step|assembly\.json)$') { $failures.Add("${name}: a package holds package.json, occurrences.json and files/<directory>/source.json, part.step or assembly.json only") }
    }
    $directories = @($present.Keys | Where-Object { $_ -match '^files/([^/]+)/' } | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
    foreach ($folder in $directories) {
        $where = "files/$folder"
        if (-not $present.Contains("$where/source.json")) { $failures.Add("$where has no source.json"); continue }
        $source = $null
        try { $source = Read-PackageJsonFile $present["$where/source.json"] } catch { $failures.Add("$where/source.json cannot be read: $($_.Exception.Message)"); continue }
        if ($source.schema_version -ne $PackageLayoutSchemaVersion) { $failures.Add("$where/source.json: schema_version must be $PackageLayoutSchemaVersion") }
        if ($source.kind -ne "part" -and $source.kind -ne "assembly") { $failures.Add("$where/source.json: kind must be part or assembly"); continue }
        if (Test-PackageHas $source "key") { $failures.Add("$where/source.json: the exporter does not write a key") }
        foreach ($field in @("name", "model_state", "vault", "export", "properties", "native", "materials")) { if (-not (Test-PackageHas $source $field)) { $failures.Add("$where/source.json has no $field") } }
        if ($source.name -isnot [string] -or -not $source.name) { $failures.Add("$where/source.json: name must be a non-empty string") }
        $vault = $source.vault
        $vaultNames = @(); if ($vault -and $vault.GetType().Name -eq "PSCustomObject") { $vaultNames = @($vault.PSObject.Properties.Name) }
        if (-not (Test-PackageSameNames $vaultNames $PackageVaultFields)) { $failures.Add("$where/source.json: vault must have exactly its nine fields"); continue }
        if ($vault.master_id -isnot [string] -or -not $vault.master_id -or $vault.version_id -isnot [string] -or -not $vault.version_id) { $failures.Add("$where/source.json: master id and version id must be non-empty strings"); continue }
        if ($null -ne $vault.version_number -and $vault.version_number -isnot [int] -and $vault.version_number -isnot [long]) { $failures.Add("$where/source.json: vault.version_number must be an integer or null") }
        if ([string]$vault.native_sha256 -notmatch '^[a-f0-9]{64}$') { $failures.Add("$where/source.json: vault.native_sha256 must be the hash of the native file") }
        if ($manifest -and $vault.vault_id -ne $manifest.vault_id) { $failures.Add("$where/source.json: the file is from another vault than the package") }
        if ((Test-PackageHas $source "export") -and (Test-PackageHas $source.export "run")) { $failures.Add("$where/source.json: export must not name a run; the import names it") }
        if ($source.properties) { foreach ($property in $PackagePropertyNames) { if (-not (Test-PackageHas $source.properties $property)) { $failures.Add("$where/source.json: properties has no $property") } }
            foreach ($property in $source.properties.PSObject.Properties) { if (-not (Test-PackageScalar $property.Value)) { $failures.Add("$where/source.json: property $($property.Name) is not a scalar") } } }
        $expected = $null; try { $expected = Get-PackageDirectoryName $vault.master_id ([string]$source.model_state) } catch { $failures.Add("$where/source.json: $($_.Exception.Message)") }
        if ($expected -and $expected -ne $folder) { $failures.Add("${where}: the directory of master id $($vault.master_id) in model state $($source.model_state) is $expected") }
        $identity = "$($vault.master_id)|$($source.model_state)"
        if ($documents.ContainsKey($identity)) { $failures.Add("${where}: master id $($vault.master_id) in model state $($source.model_state) is in the package twice"); continue }
        $record = [pscustomobject]@{ where = $where; kind = $source.kind; source = $source; assembly = $null; childByName = @{} }
        $documents[$identity] = $record
        $held = @($present.Keys | Where-Object { $_.StartsWith("$where/") } | ForEach-Object { ($_ -split '/')[2] } | Sort-Object)
        $wanted = @("source.json", $(if ($source.kind -eq "part") { "part.step" } else { "assembly.json" })) | Sort-Object
        if (-not (Test-PackageSameNames $held $wanted)) { $failures.Add("${where}: a $($source.kind) has source.json and $($wanted | Where-Object { $_ -ne 'source.json' }), and nothing else"); continue }
        if ($source.kind -eq "part") {
            $summary.parts++
            if (-not (Test-PackageHas $source "bom_structure_default")) { $failures.Add("$where/source.json has no bom_structure_default") }
            $step = $source.step
            $stepNames = @(); if ($step -and $step.GetType().Name -eq "PSCustomObject") { $stepNames = @($step.PSObject.Properties.Name) }
            if (-not (Test-PackageSameNames $stepNames $PackageStepFields)) { $failures.Add("$where/source.json: step must have exactly its seven fields"); continue }
            $path = $present["$where/part.step"]
            try {
                $info = Get-StepFileInfo -Path $path
                if ($step.sha256 -ne $info.sha256 -or $step.bytes -ne $info.bytes -or $step.data_sha256 -ne $info.data_sha256) { $failures.Add("$where/source.json: step does not describe part.step") }
                if ($step.protocol -ne $info.header.protocol) { $failures.Add("$where/source.json: step.protocol is $($step.protocol) and the file's schema says $($info.header.protocol)") }
                if ($info.header.protocol -ne "AP242") { $failures.Add("$where/part.step is $($info.header.protocol), not AP242") }
                if (@($info.header.schemas).Count -ne 1) { $failures.Add("$where/part.step names $(@($info.header.schemas).Count) schemas in FILE_SCHEMA: $(@($info.header.schemas) -join ' | ')") }
                $normalised = ($info.header.name -eq $StepNormalisedName -and $info.header.time_stamp -eq $StepNormalisedTimeStamp -and (@($info.header.author) -join '|') -eq "" -and (@($info.header.organization) -join '|') -eq "" -and $info.header.authorisation -eq "")
                if (-not $normalised -or $step.header_normalised -ne $true) { $failures.Add("$where/part.step: the header is not the normalised one, or source.json does not say it is") }
                if ($null -ne $step.received_sha256) { $failures.Add("$where/source.json: step.received_sha256 must be null (the exporter normalises before it delivers)") }
                $unit = Get-StepLengthUnit $path
                if (-not $unit.ok -or $unit.unit -ne $step.length_unit) { $failures.Add("$where/source.json: step.length_unit is $($step.length_unit) and the file declares $($unit.unit) ($($unit.reason))") }
                $invisible = Get-StepInvisibility -Path $path
                if (-not $invisible.form_understood) { $failures.Add("$where/part.step marks items invisible in a form that is not understood: $(@($invisible.problems)[0])") }
            } catch { $failures.Add("$where/part.step: $($_.Exception.Message)") }
        } else {
            $summary.assemblies++
            if (Test-PackageHas $source "step") { $failures.Add("$where/source.json: an assembly has no step record") }
            try { $record.assembly = Read-PackageJsonFile $present["$where/assembly.json"] } catch { $failures.Add("$where/assembly.json cannot be read: $($_.Exception.Message)") }
        }
    }
    # ---- the assemblies' children ----
    foreach ($record in @($documents.Values | Where-Object { $_.kind -eq "assembly" -and $_.assembly })) {
        $where = "$($record.where)/assembly.json"; $data = $record.assembly
        if ($data.schema_version -ne $PackageLayoutSchemaVersion) { $failures.Add("$where`: schema_version must be $PackageLayoutSchemaVersion") }
        if (Test-PackageHas $data "key") { $failures.Add("$where`: the exporter does not write a key") }
        if (@("mm", "cm", "m", "in") -notcontains $data.length_unit) { $failures.Add("$where`: length_unit must be mm, cm, m or in") }
        if (-not (Test-PackageHas $data "children") -or $null -eq $data.children) { $failures.Add("$where`: children must be a list"); continue }
        foreach ($child in @($data.children)) {
            $summary.children++
            if ($child.name -isnot [string] -or -not $child.name) { $failures.Add("$where`: a child has no name"); continue }
            $at = "$where $($child.name)"
            if ($record.childByName.ContainsKey($child.name) -or $child.name.Contains("/")) { $failures.Add("$at`: occurrence names are unique in an assembly and hold no '/'"); continue }
            $record.childByName[$child.name] = $child
            if (Test-PackageHas $child "component") { $failures.Add("$at`: the exporter names a component by master id and model state, not by key") }
            if (Test-PackageHas $child "overrides") { $failures.Add("$at`: this package holds the occurrences in context in occurrences.json, not overrides") }
            $target = $documents["$($child.master_id)|$($child.model_state)"]
            if (-not $target) { $failures.Add("$at`: master id $($child.master_id) in model state $($child.model_state) is not in the package"); continue }
            if ($child.kind -ne $target.kind) { $failures.Add("$at`: kind is $($child.kind) and the component is a $($target.kind)") }
            $flat = Get-PackageFlat $child.transform
            if ($null -eq $flat) { $failures.Add("$at`: transform must be 4 by 4 numbers") } else { $reason = Test-PackageRigid $flat $RotationTolerance; if ($reason) { $failures.Add("$at`: $reason") } }
            if ($PackageBomStructures -notcontains $child.bom_structure) { $failures.Add("$at`: bom_structure '$($child.bom_structure)' is not one of $($PackageBomStructures -join ', ')") }
            foreach ($flag in $PackageChildFlags) { if ($child.$flag -isnot [bool]) { $failures.Add("$at`: $flag must be true or false") } }
            if ($child.mirrored -eq $true) { $failures.Add("$at`: a mirrored child is not exported") }
        }
    }
    # ---- the root and the counts ----
    $rootRecord = $null
    if ($manifest -and (Test-PackageHas $manifest "root")) {
        $rootRecord = $documents["$($manifest.root.master_id)|$($manifest.root.model_state)"]
        if (-not $rootRecord -or $rootRecord.kind -ne "assembly") { $failures.Add("the root assembly named in package.json is not an assembly of the package"); $rootRecord = $null }
        elseif ($rootRecord.source.vault.version_id -ne $manifest.root.version_id) { $failures.Add("package.json and the root assembly's source.json name different versions") }
        if ((Test-PackageHas $manifest "counts") -and ($manifest.counts.parts -ne $summary.parts -or $manifest.counts.assemblies -ne $summary.assemblies)) { $failures.Add("package.json counts $($manifest.counts.parts) parts and $($manifest.counts.assemblies) assemblies; the package holds $($summary.parts) and $($summary.assemblies)") }
    }
    # ---- the occurrences in context ----
    if (-not $present.Contains("occurrences.json")) { $failures.Add("occurrences.json is missing") }
    else {
        $context = $null
        try { $context = Read-PackageJsonFile $present["occurrences.json"] } catch { $failures.Add("occurrences.json cannot be read: $($_.Exception.Message)") }
        if ($context) {
            if ($context.schema_version -ne $PackageOccurrencesSchemaVersion) { $failures.Add("occurrences.json: schema_version must be $PackageOccurrencesSchemaVersion") }
            $contextRoot = $documents["$($context.root.master_id)|$($context.root.model_state)"]
            if (-not $contextRoot -or $contextRoot.kind -ne "assembly") { $failures.Add("occurrences.json: its root is not an assembly of the package"); $contextRoot = $null }
            elseif ($rootRecord -and $contextRoot -ne $rootRecord) { $failures.Add("occurrences.json and package.json name different roots") }
            $nodes = @{}; $differ = 0; $expectedCount = 0
            if ($contextRoot) {
                # how many occurrences the definitions give below the root
                $stack = New-Object System.Collections.Stack; $stack.Push($contextRoot); $guard = 0
                while ($stack.Count -gt 0 -and $guard -lt 1000000) { $guard++; $current = $stack.Pop(); foreach ($child in $current.childByName.Values) { $expectedCount++; $target = $documents["$($child.master_id)|$($child.model_state)"]; if ($target -and $target.kind -eq "assembly") { $stack.Push($target) } } }
            }
            foreach ($occurrence in @($context.occurrences)) {
                $summary.occurrences++
                $path = @($occurrence.path); $id = $path -join "/"
                if ($path.Count -eq 0 -or @($path | Where-Object { $_ -isnot [string] -or -not $_ }).Count -gt 0) { $failures.Add("occurrences.json: an occurrence has no path"); continue }
                $at = "occurrences.json $id"
                if ($nodes.ContainsKey($id)) { $failures.Add("$at`: listed twice"); continue }
                $parentId = $(if ($path.Count -gt 1) { ($path[0..($path.Count - 2)]) -join "/" } else { $null })
                $parentNode = $null; $parentDocument = $contextRoot
                if ($parentId) { $parentNode = $nodes[$parentId]; if (-not $parentNode) { $failures.Add("$at`: its parent is not listed before it"); continue }; $parentDocument = $parentNode.document }
                if (-not $parentDocument -or $parentDocument.kind -ne "assembly") { $failures.Add("$at`: its parent is not an assembly"); continue }
                $definition = $parentDocument.childByName[$path[$path.Count - 1]]
                if (-not $definition) { $failures.Add("$at`: the assembly $($parentDocument.where) defines no child of that name"); continue }
                if ($occurrence.kind -ne $definition.kind -or $occurrence.master_id -ne $definition.master_id -or $occurrence.model_state -ne $definition.model_state) { $failures.Add("$at`: it is not the component its definition names") }
                $local = Get-PackageFlat $occurrence.transform; $inRoot = Get-PackageFlat $occurrence.transform_root; $defined = Get-PackageFlat $definition.transform
                if ($null -eq $local -or $null -eq $inRoot) { $failures.Add("$at`: transform and transform_root must be 4 by 4 numbers"); continue }
                foreach ($matrix in @($local, $inRoot)) { $reason = Test-PackageRigid $matrix $RotationTolerance; if ($reason) { $failures.Add("$at`: $reason") } }
                $composed = $(if ($parentNode) { Get-PackageFlatProduct $parentNode.inRoot $local } else { $local })
                $deviation = Get-PackageFlatDeviation $composed $inRoot
                if ($deviation.rotation -gt $RotationTolerance -or $deviation.length -gt $LengthTolerance) { $failures.Add("$at`: transform_root is not its parent's placement times its own") }
                $differs = $false
                if ($null -ne $defined) { $deviation = Get-PackageFlatDeviation $local $defined; $differs = ($deviation.rotation -gt $RotationTolerance -or $deviation.length -gt $LengthTolerance) }
                if ($occurrence.differs_from_definition -isnot [bool] -or $occurrence.differs_from_definition -ne $differs) { $failures.Add("$at`: differs_from_definition is $($occurrence.differs_from_definition) and the placements say $differs") }
                foreach ($flag in $PackageChildFlags) { if ($occurrence.$flag -isnot [bool]) { $failures.Add("$at`: $flag must be true or false") } }
                $flexibleAbove = $(if ($parentNode) { ($parentNode.flexible -or $parentNode.flexibleAbove) } else { $false })
                if ($differs) { $differ++; if (-not $flexibleAbove) { $failures.Add("$at`: its placement differs from its definition and no enclosing occurrence is flexible") } }
                $nodes[$id] = [pscustomobject]@{ document = $documents["$($occurrence.master_id)|$($occurrence.model_state)"]; inRoot = $inRoot; flexible = ($occurrence.flexible -eq $true); flexibleAbove = $flexibleAbove }
            }
            $summary.occurrences_that_differ_from_definition = $differ
            if ($contextRoot -and $summary.occurrences -ne $expectedCount) { $failures.Add("occurrences.json lists $($summary.occurrences) occurrences; the assemblies' definitions give $expectedCount below the root") }
            if ((Test-PackageHas $context "counts") -and ($context.counts.occurrences -ne $summary.occurrences -or $context.counts.differ_from_definition -ne $differ)) { $failures.Add("occurrences.json: its counts do not describe its list") }
        }
    }
    # ---- nothing of the workstation ----
    foreach ($hit in @(Find-PackageForbiddenText -Directory $Directory -Terms $ForbiddenTerms)) { $failures.Add($hit) }
    $summary.files = $present.Count
    return [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures); summary = $summary }
}

function Compare-PackageRuns {
    # Which files of two packages are the same bytes. package.json is expected to differ (it carries the time).
    param([Parameter(Mandatory = $true)][string]$First, [Parameter(Mandatory = $true)][string]$Second)
    $listing = {
        param($root)
        $files = Get-PackageFileMap $root; $found = [ordered]@{}
        foreach ($name in $files.Keys) { $found[$name] = (Get-PackageSha ([IO.File]::ReadAllBytes($files[$name]))) }
        return $found
    }
    $one = & $listing $First; $two = & $listing $Second
    $onlyFirst = @($one.Keys | Where-Object { -not $two.Contains($_) }); $onlySecond = @($two.Keys | Where-Object { -not $one.Contains($_) })
    $different = @($one.Keys | Where-Object { $two.Contains($_) -and $one[$_] -ne $two[$_] })
    $same = @($one.Keys | Where-Object { $two.Contains($_) -and $one[$_] -eq $two[$_] })
    $other = @($different | Where-Object { $_ -ne "package.json" })
    return [pscustomobject]@{ files_first = $one.Count; files_second = $two.Count; identical = $same.Count; different = $different; only_in_first = $onlyFirst; only_in_second = $onlySecond
        identical_except_manifest = ($onlyFirst.Count -eq 0 -and $onlySecond.Count -eq 0 -and $other.Count -eq 0); manifest_identical = ($same -contains "package.json") }
}

# ---------------------------------------------------------------------------------------------------------
# Guard queries and optional reads. Nothing here touches Inventor: these take script blocks and objects.
# ---------------------------------------------------------------------------------------------------------
function Get-RequiredValue {
    <# The value a guard needs, or an exception: when the query fails, returns nothing, returns a collection or
       returns another type than asked for. The query must return what the API returned. A cast inside it turns
       "nothing" into 0, False or "" before this function can refuse it; converting is this function's job. #>
    param([Parameter(Mandatory = $true)][string]$What, [Parameter(Mandatory = $true)][scriptblock]$Query, [ValidateSet("bool", "string", "int", "number")][string]$Kind = "bool")
    $raw = $null
    try { $raw = & $Query } catch { throw "Required guard query '$What' failed; unknown configuration refused: $($_.Exception.Message)" }
    if ($null -eq $raw) { throw "Required guard query '$What' returned null; unknown configuration refused" }
    if ($raw -is [array]) { throw "Required guard query '$What' returned a collection; unknown configuration refused" }
    switch ($Kind) {
        "bool"   { if ($raw -isnot [bool]) { throw "Required guard query '$What' returned '$raw' ($($raw.GetType().Name)), not a boolean; unknown configuration refused" }; return [bool]$raw }
        "string" { if ($raw -isnot [string] -or [string]::IsNullOrWhiteSpace($raw)) { throw "Required guard query '$What' returned an empty or non-string value ($($raw.GetType().Name)); unknown configuration refused" }; return [string]$raw }
        "int"    { if ($raw -isnot [int] -and $raw -isnot [long] -and $raw -isnot [int16] -and $raw -isnot [byte]) { throw "Required guard query '$What' returned '$raw' ($($raw.GetType().Name)), not an integer; unknown configuration refused" }; return [int]$raw }
        "number" {
            if (-not (Test-PackageNumber $raw)) { throw "Required guard query '$What' returned '$raw' ($($raw.GetType().Name)), not a number; unknown configuration refused" }
            $number = [double]$raw
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "Required guard query '$What' returned a number that is not finite; unknown configuration refused" }
            return $number
        }
    }
}
function Assert-RequiredObject {
    <# A collection or another object that a guard walks or asks must exist. Pass the object itself, assigned
       directly from the API: a COM collection that leaves a script block is enumerated, `$null.Count` is 0 and
       `foreach` over $null runs zero times, so a missing collection would otherwise pass as an empty one. #>
    param([Parameter(Mandatory = $true)][string]$What, [AllowNull()]$Object)
    if ($null -eq $Object) { throw "Required object '$What' is missing; unknown configuration refused" }
}
function Get-RequiredCount {
    # The number of items of a collection that must exist, as the collection itself reports it.
    param([Parameter(Mandatory = $true)][string]$What, [AllowNull()]$Collection)
    Assert-RequiredObject $What $Collection
    return (Get-RequiredValue "$What (count)" { $Collection.Count } -Kind int)
}
$script:PackageOptionalReadFailures = 0   # reads that failed (an exception), over the whole run of the script that dot-sourced this file
function Get-OptionalObject([scriptblock]$Query) {
    # A single object or scalar the API may not give: $null when the read fails. Not for collections (see above).
    try { return (& $Query) } catch { $script:PackageOptionalReadFailures++; return $null }
}
function Get-OptionalValue([scriptblock]$Query, [ValidateSet("double", "bool", "int", "string")][string]$As) {
    # A typed value, or $null when the read fails or the API returns nothing: a cast of $null would invent 0, False or "".
    $raw = $null
    try { $raw = & $Query } catch { $script:PackageOptionalReadFailures++; return $null }
    if ($null -eq $raw) { return $null }
    switch ($As) { "double" { return [double]$raw } "bool" { return [bool]$raw } "int" { return [int]$raw } default { return [string]$raw } }
}
function New-PackageGuardLedger([string[]]$Names) {
    # Every guard of a run with the number of times it was evaluated: 0 until the run reaches it.
    $ledger = [ordered]@{}
    foreach ($guard in $Names) { if ($ledger.Contains($guard)) { throw "The guard '$guard' is named twice" }; $ledger[$guard] = 0 }
    return $ledger
}
function Add-PackageGuardCheck($Ledger, [string]$Name, [int]$Count = 1) {
    # Called as a statement where a guard has just been evaluated and has let the run pass. It returns nothing.
    if (-not $Ledger.Contains($Name)) { throw "Unknown guard '$Name'" }
    $Ledger[$Name] = [int]$Ledger[$Name] + $Count
}

# ---------------------------------------------------------------------------------------------------------
# Every file of a directory, before and after
# ---------------------------------------------------------------------------------------------------------
function Get-PackageDirectoryHashes([string]$Directory) {
    # Every file under a directory: its relative path with SHA-256 and size.
    $files = Get-PackageFileMap $Directory; $listing = [ordered]@{}
    foreach ($name in $files.Keys) { $bytes = [IO.File]::ReadAllBytes($files[$name]); $listing[$name] = [ordered]@{ sha256 = (Get-PackageSha $bytes); bytes = $bytes.Length } }
    return $listing
}
function Compare-PackageDirectoryHashes($Before, $After) {
    # What changed, appeared or disappeared between two listings of Get-PackageDirectoryHashes.
    $changed = @(); $added = @(); $removed = @()
    foreach ($name in $Before.Keys) { if (-not $After.Contains($name)) { $removed += $name } elseif ($After[$name].sha256 -ne $Before[$name].sha256) { $changed += $name } }
    foreach ($name in $After.Keys) { if (-not $Before.Contains($name)) { $added += $name } }
    return [pscustomobject]@{ files_before = $Before.Count; files_after = $After.Count; changed = $changed; added = $added; removed = $removed; unchanged = (($changed.Count + $added.Count + $removed.Count) -eq 0) }
}

# ---------------------------------------------------------------------------------------------------------
# package.json: written last, and never left behind by something that failed after it
# ---------------------------------------------------------------------------------------------------------
function Remove-PackageManifest([string]$Directory) {
    # Takes package.json away from a package that is not complete after all. $true when none is left.
    $manifestPath = Join-Path $Directory "package.json"
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    return (-not (Test-Path -LiteralPath $manifestPath))
}
function Test-PackageRunStatus([string]$Status) {
    <# Whether a run with this status may leave a complete package: only one that ended "complete". A run that
       ended "complete_with_dialogs" had a dialog dismissed by the watchdog. What was acknowledged is in the run's
       receipt, which stays on the workstation; whoever reads the package cannot see it. #>
    return ($Status -ceq "complete")
}
function Complete-Package {
    <# Checks a written package, writes package.json and checks the package once more with it. The manifest comes
       without its "counts" and "files" (both keys present and null); they are filled here, in place. Whatever
       fails after package.json was written removes it, an exception included: the caller never gets a
       package.json that a failed check left behind. Returns ok, stage, failures, summary and manifest_written.
       -Check replaces the package check (for tests): a script block taking $true before package.json exists and
       $false after, and returning what Test-PackageOutputs returns. #>
    param([Parameter(Mandatory = $true)][string]$Directory, [Parameter(Mandatory = $true)]$Manifest, [string[]]$ForbiddenTerms = @(), [double]$RotationTolerance = 1e-9, [double]$LengthTolerance = 1e-7,
        [int]$ExpectParts = -1, [int]$ExpectAssemblies = -1, [int]$ExpectOccurrences = -1, [scriptblock]$Check = $null)
    $manifestPath = Join-Path $Directory "package.json"
    if (Test-Path -LiteralPath $manifestPath) { throw "package.json already exists in $Directory" }
    foreach ($key in @("counts", "files")) { if (-not $Manifest.Contains($key)) { throw "The manifest must have the key '$key' (null until it is filled here)" } }
    $run = $(if ($Check) { $Check } else { { param($beforeManifest) Test-PackageOutputs -Directory $Directory -ForbiddenTerms $ForbiddenTerms -AllowMissingManifest:$beforeManifest -RotationTolerance $RotationTolerance -LengthTolerance $LengthTolerance } })
    $before = & $run $true
    if (-not $before.ok) { return [pscustomobject]@{ ok = $false; stage = "before package.json"; failures = @($before.failures); summary = $before.summary; manifest_written = $false } }
    $unexpected = @()
    if ($ExpectParts -ge 0 -and $before.summary.parts -ne $ExpectParts) { $unexpected += "$($before.summary.parts) parts, $ExpectParts exported" }
    if ($ExpectAssemblies -ge 0 -and $before.summary.assemblies -ne $ExpectAssemblies) { $unexpected += "$($before.summary.assemblies) assemblies, $ExpectAssemblies exported" }
    if ($ExpectOccurrences -ge 0 -and $before.summary.occurrences -ne $ExpectOccurrences) { $unexpected += "$($before.summary.occurrences) occurrences, $ExpectOccurrences read" }
    if ($unexpected.Count -gt 0) { return [pscustomobject]@{ ok = $false; stage = "before package.json"; failures = @("the package does not hold what was exported: $($unexpected -join '; ')"); summary = $before.summary; manifest_written = $false } }
    $Manifest["counts"] = [ordered]@{ parts = $before.summary.parts; assemblies = $before.summary.assemblies }
    $Manifest["files"] = Get-PackageDirectoryHashes $Directory
    try {
        Write-PackageJsonFile $manifestPath $Manifest
        $after = & $run $false
        if (-not $after.ok) {
            [void](Remove-PackageManifest $Directory)
            return [pscustomobject]@{ ok = $false; stage = "with package.json"; failures = @($after.failures); summary = $after.summary; manifest_written = $false }
        }
        return [pscustomobject]@{ ok = $true; stage = "complete"; failures = @(); summary = $after.summary; manifest_written = $true }
    } catch {
        if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
        throw
    }
}
