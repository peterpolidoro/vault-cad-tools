<#
.SYNOPSIS
Offline tests for Package-Format.ps1 on synthetic packages. No Inventor, Vault or network.
Run:  & .\windows\Test-PackageFormat.ps1      Exit code 0 when all cases pass.
#>
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Package-Format.ps1")
$results = @()
function Case($name, [scriptblock]$body) {
    try { $detail = & $body; $script:results += [ordered]@{ case = $name; passed = $true; detail = "$detail" }; Write-Output "PASS $name $(if ($detail) { "- $detail" })" }
    catch { $script:results += [ordered]@{ case = $name; passed = $false; detail = $_.Exception.Message }; Write-Output "FAIL $name - $($_.Exception.Message)" }
}
function Assert($cond, $msg) { if (-not $cond) { throw $msg } }
function Throws([scriptblock]$body, [string]$pattern) { try { & $body | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return $true }; throw "threw '$($_.Exception.Message)', expected /$pattern/" }; throw "did not throw (expected /$pattern/)" }
$latin1 = [Text.Encoding]::GetEncoding(28591)
$work = Join-Path $env:TEMP ("vault-cad-package-format-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

# ---- a small package: a root with a plate and a flexible sub-assembly that holds a pin ----
function Get-Shift([double]$x) { return ,@(@(1.0, 0.0, 0.0, $x), @(0.0, 1.0, 0.0, 0.0), @(0.0, 0.0, 1.0, 0.0), @(0.0, 0.0, 0.0, 1.0)) }
function Get-StepText([string]$solidLines) {
    return ("ISO-10303-21;`nHEADER;`nFILE_DESCRIPTION((''),'2;1');`nFILE_NAME('part.step','1970-01-01T00:00:00',(''),(''),'ST-DEVELOPER v20','Autodesk Inventor 2025','');`n" +
        "FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }'));`nENDSEC;`nDATA;`n" +
        "#1=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));`n#2=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT(`$,.RADIAN.));`n" +
        "#4=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#1,#2)) REPRESENTATION_CONTEXT('',''));`n" + $solidLines + "`nENDSEC;`nEND-ISO-10303-21;`n")
}
$plainSolid = "#10=MANIFOLD_SOLID_BREP('Solid1',#100);`n#50=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#10),#4);"
function Get-Vault([string]$master, [string]$version) { return [ordered]@{ vault_id = "7"; master_id = $master; version_id = $version; version_number = 3; revision = "A"; lifecycle_state = "Released"; checkin_date = "2026-01-01T00:00:00Z"; path = "`$/X/$master"; native_sha256 = ("a" * 64) } }
function Get-Properties { return [ordered]@{ category = $null; description = "a part"; manufacturer = $null; material = "Aluminum 6061"; part_number = "P-1"; stock_number = $null; title = $null; vendor = $null } }
function Get-Child([string]$name, [string]$kind, [string]$master, $transform, [bool]$flexible) {
    return [ordered]@{ name = $name; kind = $kind; master_id = $master; model_state = "[Primary]"; transform = $transform; bom_structure = "Normal"; visible = $true; suppressed = $false; grounded = $false; flexible = $flexible; mirrored = $false }
}
function Get-Occurrence([string[]]$path, [string]$kind, [string]$master, $transform, $inRoot, [bool]$differs, [bool]$flexible) {
    return [ordered]@{ path = $path; kind = $kind; master_id = $master; model_state = "[Primary]"; transform = $transform; transform_root = $inRoot; differs_from_definition = $differs
        bom_structure = "Normal"; visible = $true; suppressed = $false; grounded = $false; flexible = $flexible; mirrored = $false }
}
function New-Model {
    return [ordered]@{
        steps = [ordered]@{ "100_primary" = (Get-StepText $plainSolid); "200_primary" = (Get-StepText $plainSolid) }
        sources = [ordered]@{
            "100_primary" = [ordered]@{ schema_version = 1; kind = "part"; name = "PLATE"; model_state = "[Primary]"; vault = (Get-Vault "100" "101"); step = $null; export = [ordered]@{}; properties = (Get-Properties); bom_structure_default = "Normal"; native = [ordered]@{ length_unit = "mm" }; materials = $null }
            "200_primary" = [ordered]@{ schema_version = 1; kind = "part"; name = "PIN"; model_state = "[Primary]"; vault = (Get-Vault "200" "201"); step = $null; export = [ordered]@{}; properties = (Get-Properties); bom_structure_default = "Purchased"; native = [ordered]@{ length_unit = "mm" }; materials = $null }
            "300_primary" = [ordered]@{ schema_version = 1; kind = "assembly"; name = "SUB"; model_state = "[Primary]"; vault = (Get-Vault "300" "301"); export = [ordered]@{}; properties = (Get-Properties); native = [ordered]@{ length_unit = "cm" }; materials = $null }
            "400_primary" = [ordered]@{ schema_version = 1; kind = "assembly"; name = "ROOT"; model_state = "[Primary]"; vault = (Get-Vault "400" "401"); export = [ordered]@{}; properties = (Get-Properties); native = [ordered]@{ length_unit = "cm" }; materials = $null }
        }
        assemblies = [ordered]@{
            "300_primary" = [ordered]@{ schema_version = 1; name = "SUB"; length_unit = "cm"; children = @((Get-Child "PIN:1" "part" "200" (Get-Shift 1.0) $false)) }
            "400_primary" = [ordered]@{ schema_version = 1; name = "ROOT"; length_unit = "cm"; children = @((Get-Child "SUB:1" "assembly" "300" (Get-Shift 10.0) $true), (Get-Child "PLATE:1" "part" "100" (Get-Shift 0.0) $false)) }
        }
        occurrences = [ordered]@{ schema_version = 1; root = [ordered]@{ master_id = "400"; model_state = "[Primary]" }; length_unit = "cm"; tolerance = [ordered]@{ rotation_cell = 1e-9; length = 1e-7 }
            counts = [ordered]@{ occurrences = 3; parts = 2; assemblies = 1; differ_from_definition = 1 }
            occurrences = @((Get-Occurrence @("SUB:1") "assembly" "300" (Get-Shift 10.0) (Get-Shift 10.0) $false $true), (Get-Occurrence @("SUB:1", "PIN:1") "part" "200" (Get-Shift 3.0) (Get-Shift 13.0) $true $false),
                (Get-Occurrence @("PLATE:1") "part" "100" (Get-Shift 0.0) (Get-Shift 0.0) $false $false)) }
        manifest = [ordered]@{ schema_version = 2; kind = "vault-cad-export-package"; exported_at = "2026-01-02T00:00:00Z"; exporter = [ordered]@{ name = "test"; version = $null; inventor = "test" }
            translator_options = [ordered]@{ IncludeSketches = $false; ApplicationProtocolType = 5; Author = ""; Organization = ""; Authorization = ""; Description = ""; export_fit_tolerance = 0.001; ExportUCS = $true }
            vault_id = "7"; root = [ordered]@{ master_id = "400"; version_id = "401"; model_state = "[Primary]" }; acquisition = [ordered]@{ captured_at = "2026-01-01T00:00:00Z"; method = "test" }
            counts = [ordered]@{ parts = 2; assemblies = 2 }; not_exported = @(); files = $null }
    }
}
function Write-Model($model, [string]$name, [switch]$NoManifest) {
    # Writes the model as a package directory and returns its path.
    $directory = Join-Path $work $name; New-Item -ItemType Directory -Path (Join-Path $directory "files") -Force | Out-Null
    foreach ($folder in $model.sources.Keys) {
        $target = Join-Path (Join-Path $directory "files") $folder; New-Item -ItemType Directory -Path $target | Out-Null
        $source = $model.sources[$folder]
        if ($model.steps.Contains($folder)) {
            $stepPath = Join-Path $target "part.step"; [IO.File]::WriteAllBytes($stepPath, $latin1.GetBytes($model.steps[$folder]))
            if ($null -eq $source.step) { $info = Get-StepFileInfo -Path $stepPath; $source.step = [ordered]@{ sha256 = $info.sha256; data_sha256 = $info.data_sha256; bytes = $info.bytes; protocol = $info.header.protocol; length_unit = "mm"; header_normalised = $true; received_sha256 = $null } }
        }
        if ($model.assemblies.Contains($folder)) { Write-PackageJsonFile (Join-Path $target "assembly.json") $model.assemblies[$folder] }
        Write-PackageJsonFile (Join-Path $target "source.json") $source
    }
    Write-PackageJsonFile (Join-Path $directory "occurrences.json") $model.occurrences
    if (-not $NoManifest) {
        $listed = [ordered]@{}; $files = Get-PackageFileMap $directory
        foreach ($relative in $files.Keys) { $bytes = [IO.File]::ReadAllBytes($files[$relative]); $listed[$relative] = [ordered]@{ sha256 = (Get-PackageSha $bytes); bytes = $bytes.Length } }
        $model.manifest.files = $listed
        Write-PackageJsonFile (Join-Path $directory "package.json") $model.manifest
    }
    return $directory
}
function Get-Failures($model, [string]$name) { return @((Test-PackageOutputs -Directory (Write-Model $model $name)).failures) }

try {
    # ---- JSON ----
    Case "P1 JSON: keys in the order given, two spaces, a list of scalars on one line, LF" {
        $text = ConvertTo-PackageJson ([ordered]@{ b = 1; a = @("x", $null, $true, 2); c = [ordered]@{ d = @() ; e = [ordered]@{} }; f = @([ordered]@{ g = 1 }) })
        $expected = "{`n  `"b`": 1,`n  `"a`": [`"x`", null, true, 2],`n  `"c`": {`n    `"d`": [],`n    `"e`": {}`n  },`n  `"f`": [`n    {`n      `"g`": 1`n    }`n  ]`n}"
        Assert ($text -ceq $expected) "text: $text"
    }
    Case "P2 JSON: a double is written so that it reads back the same, and stays a double" {
        foreach ($value in @(0.1, (0.1 + 0.2), 1.0, -0.0, 1e-5, 12345678.9, 0.84551240822557006, [Math]::PI, 2.2204460492503131E-16, 1e300)) {
            $text = ConvertTo-PackageJson $value
            Assert ($text -match '[.eE]') "no decimal point or exponent in $text"
            Assert ([double]::Parse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture) -eq $value) "$value was written as $text"
        }
        Assert ((ConvertTo-PackageJson 1.0) -ceq "1.0" -and (ConvertTo-PackageJson 3) -ceq "3" -and (ConvertTo-PackageJson ([long]4000000000)) -ceq "4000000000" -and (ConvertTo-PackageJson (0.1 + 0.2)) -ceq "0.30000000000000004") "plain forms"
    }
    Case "P3 JSON: a matrix stays a list of rows, also with one row; a custom object is written like a dictionary" {
        Assert ((ConvertTo-PackageJson (Get-Shift 2.5)) -ceq "[`n  [1.0, 0.0, 0.0, 2.5],`n  [0.0, 1.0, 0.0, 0.0],`n  [0.0, 0.0, 1.0, 0.0],`n  [0.0, 0.0, 0.0, 1.0]`n]") "matrix: $(ConvertTo-PackageJson (Get-Shift 2.5))"
        Assert ((ConvertTo-PackageJson @(, @(1.0, 2.0))) -ceq "[`n  [1.0, 2.0]`n]") "one row: $(ConvertTo-PackageJson @(, @(1.0, 2.0)))"
        Assert ((ConvertTo-PackageJson ([pscustomobject]@{ a = "x"; b = @(1, 2) })) -ceq "{`n  `"a`": `"x`",`n  `"b`": [1, 2]`n}") "custom object"
    }
    Case "P4 JSON: quotes, backslashes and control characters are escaped; other characters are written as they are, in UTF-8 without a byte-order mark" {
        $value = [ordered]@{ text = ("a`"b\c`td`ne" + [char]1 + [char]233 + [char]0x2028) }
        $path = Join-Path $work "escape.json"; Write-PackageJsonFile $path $value
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert ($bytes[0] -eq 0x7B -and $bytes[$bytes.Length - 1] -eq 0x0A -and @($bytes | Where-Object { $_ -eq 0x0D }).Count -eq 0) "byte-order mark, no trailing newline, or a carriage return"
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        Assert ($text -ceq ("{`n  `"text`": `"a\`"b\\c\td\ne\u0001" + [char]233 + [char]0x2028 + "`"`n}`n")) "text: $text"
        Assert ((Read-PackageJsonFile $path).text -ceq $value.text) "does not read back"
        [void](Throws { Write-PackageJsonFile $path $value } 'overwrite')
    }
    Case "P5 JSON: a number that is not finite, a date, a COM-like object and a key that is not a string are refused" {
        [void](Throws { ConvertTo-PackageJson ([double]::NaN) } 'not finite')
        [void](Throws { ConvertTo-PackageJson ([ordered]@{ a = [double]::PositiveInfinity }) } 'not finite')
        [void](Throws { ConvertTo-PackageJson ([ordered]@{ a = (Get-Date) }) } 'cannot be written')
        [void](Throws { ConvertTo-PackageJson ([ordered]@{ a = [guid]::NewGuid() }) } 'cannot be written')
        [void](Throws { ConvertTo-PackageJson (@{ 1 = "x" }) } 'not a string')
    }
    # ---- names and the vault block ----
    Case "P6 directory names: the model state in lower case with single hyphens; a master id that cannot name a directory is refused" {
        Assert ((Get-PackageDirectoryName "953898" "[Primary]") -ceq "953898_primary") "primary: $(Get-PackageDirectoryName '953898' '[Primary]')"
        Assert ((Get-PackageDirectoryName "12" "  Model State (2) ") -ceq "12_model-state-2" -and (Get-PackageDirectoryName "12" "") -ceq "12_" -and (Get-PackageStateName "A__b") -ceq "a-b") "other states"
        [void](Throws { Get-PackageDirectoryName "a/b" "x" } 'cannot name a directory')
        [void](Throws { Get-PackageDirectoryName "" "x" } 'cannot name a directory')
    }
    Case "P7 the vault block: nine fields from the two records of one version; disagreeing records are refused; an unknown fact is null" {
        $acquired = [pscustomobject]@{ version_id = "906736"; master_id = "805815"; vault_path = '$/DATA/A.ipt'; sha256 = ("AB" * 32) }
        $listed = [pscustomobject]@{ version_id = "906736"; master_id = "805815"; vault_path = '$/DATA/A.ipt'; version = 3; revision = "0"; state = "Work in Progress"; checkin_date = "2024-02-21T08:10:05.197Z" }
        $block = New-PackageVaultBlock -VaultId "28" -AcquisitionRecord $acquired -InventoryRecord $listed
        Assert ((@($block.Keys) -join ',') -ceq ($PackageVaultFields -join ',')) "fields: $(@($block.Keys) -join ',')"
        Assert ($block.vault_id -ceq "28" -and $block.version_number -eq 3 -and $block.version_number -is [int] -and $block.revision -ceq "0" -and $block.lifecycle_state -ceq "Work in Progress" -and $block.checkin_date -ceq "2024-02-21T08:10:05.197Z" -and $block.path -ceq '$/DATA/A.ipt' -and $block.native_sha256 -ceq ("ab" * 32)) "values: $($block | ConvertTo-Json -Compress)"
        $unknown = New-PackageVaultBlock -VaultId "28" -AcquisitionRecord $acquired -InventoryRecord ([pscustomobject]@{ version_id = "906736"; master_id = "805815"; vault_path = '$/DATA/A.ipt'; version = "three"; revision = $null; state = $null; checkin_date = $null })
        Assert ($null -eq $unknown.version_number -and $null -eq $unknown.revision -and $null -eq $unknown.checkin_date -and (ConvertTo-PackageJson $unknown).Contains('"version_number": null')) "unknown facts: $($unknown | ConvertTo-Json -Compress)"
        [void](Throws { New-PackageVaultBlock -VaultId "28" -AcquisitionRecord $acquired -InventoryRecord ([pscustomobject]@{ version_id = "906736"; master_id = "1"; vault_path = '$/DATA/A.ipt' }) } 'disagree')
        [void](Throws { New-PackageVaultBlock -VaultId "28" -AcquisitionRecord ([pscustomobject]@{ version_id = "906736"; master_id = "805815"; vault_path = '$/DATA/A.ipt'; sha256 = "short" }) -InventoryRecord $listed } 'SHA-256')
    }
    # ---- a written package ----
    Case "P8 a consistent package passes, with its counts" {
        $verdict = Test-PackageOutputs -Directory (Write-Model (New-Model) "good")
        Assert ($verdict.ok) "failures: $($verdict.failures -join ' | ')"
        Assert ($verdict.summary.parts -eq 2 -and $verdict.summary.assemblies -eq 2 -and $verdict.summary.children -eq 3 -and $verdict.summary.occurrences -eq 3 -and $verdict.summary.occurrences_that_differ_from_definition -eq 1 -and $verdict.summary.files -eq 10) "summary: $($verdict.summary | ConvertTo-Json -Compress)"
        "10 files"
    }
    Case "P9 a package without package.json is not complete, unless the check is the one made before it is written" {
        $directory = Write-Model (New-Model) "nomanifest" -NoManifest
        Assert ((@((Test-PackageOutputs -Directory $directory).failures) -join ';') -match 'package.json is missing') "a package without package.json passed"
        $early = Test-PackageOutputs -Directory $directory -AllowMissingManifest
        Assert ($early.ok) "failures: $($early.failures -join ' | ')"
    }
    Case "P10 a file that is not listed, a listed file that changed, and a file that does not belong are found" {
        $directory = Write-Model (New-Model) "tampered"
        [IO.File]::WriteAllText((Join-Path $directory "files\100_primary\notes.txt"), "x")
        [IO.File]::AppendAllText((Join-Path $directory "files\200_primary\source.json"), " ")
        $text = @((Test-PackageOutputs -Directory $directory).failures) -join ';'
        Assert ($text -match 'files/100_primary/notes.txt is in the package and not listed' -and $text -match 'files/200_primary/source.json does not match package.json' -and $text -match 'notes.txt: a package holds') "failures: $text"
    }
    Case "P11 source.json: a key, a missing vault field, a run, a step record that does not describe the file, and a wrong directory are refused" {
        $model = New-Model; $model.sources["100_primary"]["key"] = "plate"; Assert ((Get-Failures $model "s1") -match 'does not write a key') "key"
        $model = New-Model; $model.sources["100_primary"].vault.Remove("revision"); Assert ((Get-Failures $model "s2") -match 'exactly its nine fields') "vault fields"
        $model = New-Model; $model.sources["100_primary"].export["run"] = "r1"; Assert ((Get-Failures $model "s3") -match 'must not name a run') "run"
        $model = New-Model; $model.sources["100_primary"].step = [ordered]@{ sha256 = ("0" * 64); data_sha256 = ("0" * 64); bytes = 1; protocol = "AP242"; length_unit = "mm"; header_normalised = $true; received_sha256 = $null }; Assert ((Get-Failures $model "s4") -match 'step does not describe part.step') "step"
        $model = New-Model; $model.sources["100_primary"].vault.master_id = "999"; Assert ((Get-Failures $model "s5") -match 'the directory of master id 999 in model state \[Primary\] is 999_primary') "directory"
        $model = New-Model; $model.sources["100_primary"].properties.Remove("vendor"); Assert ((Get-Failures $model "s6") -match 'properties has no vendor') "properties"
        $model = New-Model; $model.sources["100_primary"].vault.version_number = "3"; Assert ((Get-Failures $model "s7") -match 'version_number must be an integer or null') "version number"
    }
    Case "P12 part.step: a header that is not normalised, another protocol, a second schema name, another unit and an INVISIBILITY in another form are refused" {
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $plainSolid).Replace("('part.step','1970-01-01T00:00:00',('')", "('PLATE.step','2026-01-01T00:00:00',('someone')"); Assert ((Get-Failures $model "t1") -match 'the header is not the normalised one') "header"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $plainSolid).Replace("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }", "AUTOMOTIVE_DESIGN { 1 0 10303 214 3 1 1 }"); Assert ((Get-Failures $model "t2") -match 'is AP214, not AP242') "protocol"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $plainSolid).Replace("FILE_SCHEMA(('AP242_", "FILE_SCHEMA(('FEATURE_BASED_PROCESS_PLANNING','AP242_"); $text = (Get-Failures $model "t2b") -join ';'; Assert ($text -match 'names 2 schemas in FILE_SCHEMA' -and $text -match 'part.step is , not AP242') "two schemas: $text"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $plainSolid).Replace("FILE_SCHEMA(('AP242_", "FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }','AP242_"); Assert ((Get-Failures $model "t2c") -match 'names 2 schemas in FILE_SCHEMA') "two schemas, the first of them AP242"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $plainSolid).Replace(".MILLI.", ".CENTI."); Assert ((Get-Failures $model "t3") -match 'step.length_unit is mm and the file declares cm') "unit"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText "#10=MANIFOLD_SOLID_BREP('Solid1',#100);`n#40=INVISIBILITY((#10));`n#50=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#10),#4);"); Assert ((Get-Failures $model "t4") -match 'marks items invisible in a form that is not understood') "invisibility"
        $hidden = "#10=MANIFOLD_SOLID_BREP('Solid1',#100);`n#11=MANIFOLD_SOLID_BREP('Solid2',#101);`n#20=STYLED_ITEM('',(#30),#11);`n#40=INVISIBILITY((#20));`n#50=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#10,#11),#4);"
        $model = New-Model; $model.steps["100_primary"] = (Get-StepText $hidden); Assert (@(Get-Failures $model "t5").Count -eq 0) "an INVISIBILITY in the understood form was refused"
    }
    Case "P13 assembly.json: a key, a component key, overrides, a missing component, a wrong kind, a mirrored or skewed placement, a repeated name and an unknown BOM structure are refused" {
        $model = New-Model; $model.assemblies["400_primary"]["key"] = "root"; Assert ((Get-Failures $model "a1") -match 'assembly.json: the exporter does not write a key') "key"
        $model = New-Model; $model.assemblies["400_primary"].children[1]["component"] = "plate"; Assert ((Get-Failures $model "a2") -match 'names a component by master id and model state') "component"
        $model = New-Model; $model.assemblies["400_primary"].children[0]["overrides"] = @(); Assert ((Get-Failures $model "a3") -match 'not overrides') "overrides"
        $model = New-Model; $model.assemblies["400_primary"].children[1].master_id = "555"; Assert ((Get-Failures $model "a4") -match 'master id 555 in model state \[Primary\] is not in the package') "missing component"
        $model = New-Model; $model.assemblies["400_primary"].children[1].kind = "assembly"; Assert ((Get-Failures $model "a5") -match 'kind is assembly and the component is a part') "kind"
        $model = New-Model; $model.assemblies["400_primary"].children[1].transform = @(@(-1.0, 0.0, 0.0, 0.0), @(0.0, 1.0, 0.0, 0.0), @(0.0, 0.0, 1.0, 0.0), @(0.0, 0.0, 0.0, 1.0)); Assert ((Get-Failures $model "a6") -match 'mirrored') "mirrored"
        $model = New-Model; $model.assemblies["400_primary"].children[1].transform = @(@(1.0, 0.1, 0.0, 0.0), @(0.0, 1.0, 0.0, 0.0), @(0.0, 0.0, 1.0, 0.0), @(0.0, 0.0, 0.0, 1.0)); Assert ((Get-Failures $model "a7") -match 'not orthonormal') "skewed"
        $model = New-Model; $model.assemblies["400_primary"].children[1].name = "SUB:1"; Assert ((Get-Failures $model "a8") -match 'occurrence names are unique') "repeated name"
        $model = New-Model; $model.assemblies["400_primary"].children[1].bom_structure = "Varies"; Assert ((Get-Failures $model "a9") -match "bom_structure 'Varies' is not one of") "BOM structure"
        $model = New-Model; $model.assemblies["400_primary"].children[1].visible = "yes"; Assert ((Get-Failures $model "a10") -match 'visible must be true or false') "flag"
    }
    Case "P14 occurrences.json: a placement that differs with no flexible occurrence above it, a wrong flag, a wrong placement in the root, a missing or unknown occurrence are refused" {
        $model = New-Model; $model.assemblies["400_primary"].children[0].flexible = $false; $model.occurrences.occurrences[0].flexible = $false; Assert ((Get-Failures $model "o1") -match 'SUB:1/PIN:1: its placement differs from its definition and no enclosing occurrence is flexible') "not flexible"
        $model = New-Model; $model.occurrences.occurrences[1].differs_from_definition = $false; Assert ((Get-Failures $model "o2") -match 'differs_from_definition is False and the placements say True') "flag"
        $model = New-Model; $model.occurrences.occurrences[1].transform_root = (Get-Shift 14.0); Assert ((Get-Failures $model "o3") -match "transform_root is not its parent's placement times its own") "placement in the root"
        $model = New-Model; $model.occurrences.occurrences = @($model.occurrences.occurrences[0], $model.occurrences.occurrences[1]); $model.occurrences.counts.occurrences = 2; Assert ((Get-Failures $model "o4") -match "lists 2 occurrences; the assemblies' definitions give 3") "missing occurrence"
        $model = New-Model; $model.occurrences.occurrences[2].path = @("PLATE:9"); Assert ((Get-Failures $model "o5") -match 'defines no child of that name') "unknown occurrence"
        $model = New-Model; $model.occurrences.occurrences[1].master_id = "100"; Assert ((Get-Failures $model "o6") -match 'it is not the component its definition names') "another component"
        $model = New-Model; $model.occurrences.counts.differ_from_definition = 0; Assert ((Get-Failures $model "o7") -match 'its counts do not describe its list') "counts"
    }
    Case "P15 package.json: another protocol, a filled author option, a root that is not in the package and wrong counts are refused" {
        $model = New-Model; $model.manifest.translator_options.ApplicationProtocolType = 3; Assert ((Get-Failures $model "m1") -match 'ApplicationProtocolType is not 5') "protocol"
        $model = New-Model; $model.manifest.translator_options.Author = "someone"; Assert ((Get-Failures $model "m2") -match 'Author is not empty') "author"
        $model = New-Model; $model.manifest.root.master_id = "100"; Assert ((Get-Failures $model "m3") -match 'the root assembly named in package.json is not an assembly of the package') "root"
        $model = New-Model; $model.manifest.root.version_id = "999"; Assert ((Get-Failures $model "m4") -match 'name different versions') "root version"
        $model = New-Model; $model.manifest.counts.parts = 3; Assert ((Get-Failures $model "m5") -match 'counts 3 parts and 2 assemblies; the package holds 2 and 2') "counts"
        $model = New-Model; $model.manifest.Remove("not_exported"); Assert ((Get-Failures $model "m6") -match 'package.json has no not_exported') "not_exported"
    }
    Case "P16 forbidden text: a drive path or a share in a JSON file, and a given name as a whole word in any file, whatever its case" {
        $model = New-Model; $model.sources["100_primary"].native["document"] = "C:\Users\someone\part.ipt"; Assert ((Get-Failures $model "f1") -match 'files/100_primary/source.json holds a path with a drive letter') "drive path"
        $model = New-Model; $model.sources["100_primary"].native["document"] = "\\server\share\part.ipt"; Assert ((Get-Failures $model "f2") -match 'holds a path on a share') "share"
        $model = New-Model; $model.sources["100_primary"].properties.description = "made by JSMITH"; $model.steps["200_primary"] = (Get-StepText ($plainSolid + "`n#60=PERSON('jsmith');"))
        $directory = Write-Model $model "f3"
        $hits = @(Find-PackageForbiddenText -Directory $directory -Terms @("jsmith", "ann", "WORKSTATION-7"))
        Assert ($hits.Count -eq 2 -and ($hits -join ';') -match "files/100_primary/source.json holds 'jsmith'" -and ($hits -join ';') -match "files/200_primary/part.step holds 'jsmith'") "hits: $($hits -join ' | ')"
        $model = New-Model; $model.sources["100_primary"].properties.description = "a channel for Joanne"; $directory = Write-Model $model "f4"
        Assert (@(Find-PackageForbiddenText -Directory $directory -Terms @("ann", "anne")).Count -eq 0) "a name inside another word was reported"
        $model = New-Model; $model.sources["100_primary"].native["note"] = "D:\work\mirror\x"; $directory = Write-Model $model "f5"
        Assert ((@(Find-PackageForbiddenText -Directory $directory -Terms @("D:\work\mirror")) -join ';') -match "holds 'D:\\work\\mirror'") "a path term written with doubled backslashes was not found"
        Assert ((@((Test-PackageOutputs -Directory (Write-Model (New-Model) "f6") -ForbiddenTerms @("PLATE")).failures) -join ';') -match "holds 'PLATE'") "Test-PackageOutputs did not apply the terms"
    }
    Case "P17 two runs: identical except package.json; a differing file, and a file in one run only, are found" {
        $first = Write-Model (New-Model) "run-a"; $model = New-Model; $model.manifest.exported_at = "2026-01-03T00:00:00Z"; $second = Write-Model $model "run-b"
        $same = Compare-PackageRuns -First $first -Second $second
        Assert ($same.identical_except_manifest -and -not $same.manifest_identical -and $same.identical -eq 9 -and (@($same.different) -join ',') -ceq "package.json") "comparison: $($same | ConvertTo-Json -Compress)"
        $model = New-Model; $model.occurrences.occurrences[1].transform = (Get-Shift 3.0000001); $third = Write-Model $model "run-c"
        [IO.File]::WriteAllText((Join-Path $third "extra.txt"), "x")
        $other = Compare-PackageRuns -First $first -Second $third
        Assert (-not $other.identical_except_manifest -and (@($other.different) -contains "occurrences.json") -and (@($other.only_in_second) -join ',') -ceq "extra.txt") "comparison: $($other | ConvertTo-Json -Compress)"
    }
} finally { Remove-Item -LiteralPath $work -Recurse -Force }
$passed = @($results | Where-Object passed).Count; $failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "$passed passed, $failed failed"
if ($env:VAULT_CAD_TEST_JSON) { $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:VAULT_CAD_TEST_JSON -Encoding UTF8 }
if ($failed -gt 0) { exit 1 }
