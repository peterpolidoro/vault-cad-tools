<#
.SYNOPSIS
Export one STEP per distinct part geometry of a native assembly plus an occurrence/hierarchy manifest.

.DESCRIPTION
Walks instance occurrences (including flexible subassembly proxies), derives local transforms
from world transforms, and cross-checks placements against Inventor proxy bounds.
Writes under -OutputDirectory:
  assets/<part>.step             one STEP (local frame, AP214, no sketches) per distinct
                                  part document + model state; multibody parts stay one asset
  native-snapshot.json           raw Inventor data: cm, native axes, numeric enums, properties
  scene.json                     adapter to the mechanical-docs draft-1 contract: mm, 4x4 row-major
                                  matrices for column vectors, translation in the last column,
                                  parent@child, with the native up-axis DECLARED (not silently
                                  converted) and a basis_to_z_up matrix supplied for consumers
  inventory-raw.json             per-part instance counts with native BOM structure; not stock
  export-receipt.json            hashes of everything written, source Vault ids via acquisition
Nothing is saved to native files. Mirrored occurrences (negative determinant) are flagged.
Occurrence ids are the snapshot-scoped occurrence paths; names can change between revisions.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Acquisition,
    [string]$Inventory,
    [int]$ApplicationProtocolType = 3,
    [string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $NativeAssembly)) { throw "Assembly not found: $NativeAssembly" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
foreach ($n in "native-snapshot.json", "scene.json", "inventory-raw.json", "export-receipt.json") { if (Test-Path -LiteralPath (Join-Path $OutputDirectory $n)) { throw "Refusing to overwrite $n in $OutputDirectory" } }
$assetsDir = Join-Path $OutputDirectory "assets"; New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$acq = @{}; if ($Acquisition) { foreach ($a in (Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json).files) { $acq[([string]$a.local_path).ToLowerInvariant()] = $a } }
$inv = @{}; if ($Inventory) { foreach ($f in (Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json).files) { $inv[[string]$f.version_id] = $f } }
$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$bomNames = @{ 51969 = "Default"; 51970 = "Normal"; 51971 = "Phantom"; 51972 = "Reference"; 51973 = "Purchased"; 51974 = "Inseparable"; 51975 = "Varies" }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-MapName($map, $i) { $map.GetType().InvokeMember("Name", [Reflection.BindingFlags]::GetProperty, $null, $map, @($i)) }
function Get-MapValue($map, $k) { $map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::GetProperty, $null, $map, @($k)) }
function Set-MapValue($map, $k, $v) { [void]$map.GetType().InvokeMember("Value", [Reflection.BindingFlags]::SetProperty, $null, $map, @($k, $v)) }
function Read-Map($map) { $r = [ordered]@{}; for ($i = 1; $i -le $map.Count; $i++) { $n = Get-MapName $map $i; $r[$n] = Get-MapValue $map $n }; return $r }
function Cells($m) { $rows = @(); for ($r = 1; $r -le 4; $r++) { $row = @(); for ($c = 1; $c -le 4; $c++) { $row += [double]$m.GetType().InvokeMember("Cell", [Reflection.BindingFlags]::GetProperty, $null, $m, @($r, $c)) }; $rows += ,$row }; return ,$rows }
function Mul($A, $B) { $R = @(); for ($i = 0; $i -lt 4; $i++) { $row = @(); for ($j = 0; $j -lt 4; $j++) { $s = 0.0; for ($k = 0; $k -lt 4; $k++) { $s += $A[$i][$k] * $B[$k][$j] }; $row += $s }; $R += ,$row }; return ,$R }
function ToMm($M) { $R = @(); for ($i = 0; $i -lt 4; $i++) { $row = @(); for ($j = 0; $j -lt 4; $j++) { $v = $M[$i][$j]; if ($j -eq 3 -and $i -lt 3) { $v = $v * 10.0 }; $row += $v }; $R += ,$row }; return ,$R }
function Det3($M) { $M[0][0]*($M[1][1]*$M[2][2]-$M[1][2]*$M[2][1]) - $M[0][1]*($M[1][0]*$M[2][2]-$M[1][2]*$M[2][0]) + $M[0][2]*($M[1][0]*$M[2][1]-$M[1][1]*$M[2][0]) }
$Identity = @(@(1.0,0.0,0.0,0.0),@(0.0,1.0,0.0,0.0),@(0.0,0.0,1.0,0.0),@(0.0,0.0,0.0,1.0))
function Prop($doc, $set, $name) { try { return $doc.PropertySets.Item($set).Item($name).Value } catch { return $null } }
function Safe($s) { ($s -replace '[\\/:*?"<>|]', '_') -replace '\s+', ' ' }
function Box($rb) { [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z); extent = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z)) } }
function Get-StepLengthUnit($path) {
    # The geometry's length unit is the LENGTH_UNIT entity referenced from GLOBAL_UNIT_ASSIGNED_CONTEXT.
    try {
        $txt = [IO.File]::ReadAllText($path)
        $ctx = [regex]::Match($txt, 'GLOBAL_UNIT_ASSIGNED_CONTEXT\s*\(\s*\(([^)]*)\)')
        if (-not $ctx.Success) { return [ordered]@{ unit = $null; method = "no GLOBAL_UNIT_ASSIGNED_CONTEXT" } }
        foreach ($ref in ([regex]::Matches($ctx.Groups[1].Value, '#(\d+)') | ForEach-Object { $_.Groups[1].Value })) {
            $e = [regex]::Match($txt, "(?s)(?m)^#$ref\s*=\s*(.*?);")
            if (-not $e.Success) { continue }
            $def = ($e.Groups[1].Value -replace '\s+', ' ').Trim()
            if ($def -notmatch 'LENGTH_UNIT\s*\(\s*\)') { continue }
            $unit = if ($def -match "SI_UNIT\s*\(\s*\.CENTI\.\s*,\s*\.METRE\.") { "cm" } elseif ($def -match "SI_UNIT\s*\(\s*\.MILLI\.\s*,\s*\.METRE\.") { "mm" } elseif ($def -match "SI_UNIT\s*\(\s*\\$\s*,\s*\.METRE\.") { "m" } elseif ($def -match "(?i)CONVERSION_BASED_UNIT\s*\(\s*'inch'") { "in" } elseif ($def -match "(?i)CONVERSION_BASED_UNIT\s*\(\s*'foot'") { "ft" } else { $null }
            return [ordered]@{ unit = $unit; method = "GLOBAL_UNIT_ASSIGNED_CONTEXT -> #$ref"; entity = $def }
        }
        return [ordered]@{ unit = $null; method = "no LENGTH_UNIT entity among context units" }
    } catch { return [ordered]@{ unit = $null; method = "parse error: $($_.Exception.Message)" } }
}

$before = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$app = New-Object -ComObject Inventor.Application
Start-Sleep -Seconds 3
$after = @(Get-Process -Name Inventor -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids = @($after | Where-Object { $before -notcontains $_ })
if ($newPids.Count -eq 0) { Write-Output "COM attached to an already running Inventor instance; aborting."; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app); exit 3 }
Write-Output "New Inventor instance pid $($newPids -join ',') version $($app.SoftwareVersion.DisplayVersion) build $($app.SoftwareVersion.BuildIdentifier)"
$dpm = $null; $proj = $null; $previous = $null; $errors = @()
$parts = [ordered]@{}; $groups = @(); $occs = @(); $warnings = @()
try {
    $app.Visible = $false; $app.SilentOperation = $true
    $dpm = $app.DesignProjectManager; $previous = $dpm.ActiveDesignProject.FullFileName
    $ipj = Join-Path $WorkspaceRoot "$ProjectName.ipj"
    if (-not (Test-Path -LiteralPath $ipj)) { Copy-Item -LiteralPath $TemplateProject -Destination $ipj }
    foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $ipj) { $proj = $p } }
    if (-not $proj) { $proj = $dpm.DesignProjects.AddExisting($ipj) }
    $proj.Activate($false)
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects
    Write-Output "Opening $NativeAssembly"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        $rootDef = $asm.ComponentDefinition
        $rootUnits = $lengthUnitNames[[int]$asm.UnitsOfMeasure.LengthUnits]
        $missing = @(); foreach ($rd in @($asm) + @($asm.AllReferencedDocuments)) { foreach ($fd in $rd.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing) { $missing += $fd.FullFileName } } }
        if ($missing.Count -gt 0) { throw "Unresolved references: $($missing -join '; ')" }

        function Part-Key($doc, $modelState) { $rel = $doc.FullFileName; if ($rel.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant())) { $rel = $rel.Substring($WorkspaceRoot.Length).TrimStart('\') }; return "$rel|$modelState" }
        function Ensure-Part($occ) {
            $doc = $occ.Definition.Document
            $ms = $(try { $occ.ActiveModelState } catch { try { $occ.Definition.ModelStates.ActiveModelState.Name } catch { "n/a" } })
            $key = Part-Key $doc $ms
            if ($parts.Contains($key)) { return $key }
            $base = [IO.Path]::GetFileNameWithoutExtension($doc.FullFileName)
            $suffix = (Sha-String $key).Substring(0, 8)
            $assetName = (Safe "$base`__$(Safe $ms)__$suffix") + ".step"
            $assetPath = Join-Path $assetsDir $assetName
            $cd = $doc.ComponentDefinition
            $bodies = 0; $solids = 0; $visible = 0; foreach ($b in $cd.SurfaceBodies) { $bodies++; $s = $false; try { $s = [bool]$b.IsSolid } catch { }; if ($s) { $solids++; if ($b.Visible) { $visible++ } } }
            $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
            $opts = $to.CreateNameValueMap()
            if ($translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
            $medium = $to.CreateDataMedium(); $medium.FileName = $assetPath
            $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
            $a = $acq[$doc.FullFileName.ToLowerInvariant()]
            # Inventor files declare several length units (cm, mm, sometimes 'inch'); the one that governs
            # the geometry is the LENGTH_UNIT referenced by GLOBAL_UNIT_ASSIGNED_CONTEXT. Resolve that entity.
            $lu = Get-StepLengthUnit $assetPath; $stepUnit = $lu.unit
            $parts[$key] = [ordered]@{ id = $key; document = $doc.FullFileName; model_state = $ms; display_name = $doc.DisplayName
                asset = [ordered]@{ path = "assets/$assetName"; format = "step"; protocol = "AP214"; sha256 = (Sha $assetPath); bytes = (Get-Item -LiteralPath $assetPath).Length; step_length_unit = $stepUnit; step_length_unit_detection = $lu; translator_options = (Read-Map $opts) }
                native_length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]; range_box_cm = (Box $cd.RangeBox)
                bodies = [ordered]@{ surface_bodies = $bodies; solid_bodies = $solids; visible_solid_bodies = $visible }
                volume_cm3 = $(try { [double]$cd.MassProperties.Volume } catch { $null })
                default_bom_structure = [ordered]@{ value = [int]$cd.BOMStructure; name = $bomNames[[int]$cd.BOMStructure] }
                properties = [ordered]@{ part_number = (Prop $doc "Design Tracking Properties" "Part Number"); description = (Prop $doc "Design Tracking Properties" "Description"); material = (Prop $doc "Design Tracking Properties" "Material"); stock_number = (Prop $doc "Design Tracking Properties" "Stock Number"); vendor = (Prop $doc "Design Tracking Properties" "Vendor"); manufacturer = (Prop $doc "Design Tracking Properties" "Manufacturer"); title = (Prop $doc "Inventor Summary Information" "Title"); category = (Prop $doc "Inventor Document Summary Information" "Category") }
                source = $(if ($a) { [ordered]@{ vault_id = "28"; version_id = [string]$a.version_id; master_id = [string]$a.master_id; vault_path = $a.vault_path; native_sha256 = $a.sha256; native_sha256_now = (Sha $doc.FullFileName) } } else { [ordered]@{ note = "not in acquisition record" } })
                instance_count = 0 }
            return $key
        }
        function Sha-String($s) { $sha = [Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').ToLowerInvariant() }

        # Walk the INSTANCE tree (root occurrences, then SubOccurrences proxies). Proxy transforms are in
        # the top-level assembly context, so they carry instance-specific positions of flexible
        # sub-assemblies; the parent-from-child local transform is derived as inv(parentWorld) * world.
        # NativeObject.Transformation (the occurrence in its own definition) is recorded for comparison:
        # a difference means the instance position is overridden (flexible assembly / positional rep).
        function InvRigid($M) {
            $R = @(); for ($i = 0; $i -lt 3; $i++) { $row = @(); for ($j = 0; $j -lt 3; $j++) { $row += [double]$M[$j][$i] }; $row += 0.0; $R += ,$row }
            $t = @($M[0][3], $M[1][3], $M[2][3])
            for ($i = 0; $i -lt 3; $i++) { $R[$i][3] = -($R[$i][0] * $t[0] + $R[$i][1] * $t[1] + $R[$i][2] * $t[2]) }
            $R += ,@(0.0, 0.0, 0.0, 1.0); return ,$R
        }
        function MaxDiff($A, $B) { $m = 0.0; for ($i = 0; $i -lt 4; $i++) { for ($j = 0; $j -lt 4; $j++) { $d = [Math]::Abs([double]$A[$i][$j] - [double]$B[$i][$j]); if ($d -gt $m) { $m = $d } } }; return $m }
        function Transform-Box($box, $M) {
            $pts = @(); foreach ($x in @($box.min[0], $box.max[0])) { foreach ($y in @($box.min[1], $box.max[1])) { foreach ($z in @($box.min[2], $box.max[2])) { $pts += ,@(($M[0][0]*$x + $M[0][1]*$y + $M[0][2]*$z + $M[0][3]), ($M[1][0]*$x + $M[1][1]*$y + $M[1][2]*$z + $M[1][3]), ($M[2][0]*$x + $M[2][1]*$y + $M[2][2]*$z + $M[2][3])) } } }
            [ordered]@{ min = @(($pts | ForEach-Object { $_[0] } | Measure-Object -Minimum).Minimum, ($pts | ForEach-Object { $_[1] } | Measure-Object -Minimum).Minimum, ($pts | ForEach-Object { $_[2] } | Measure-Object -Minimum).Minimum); max = @(($pts | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum, ($pts | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum, ($pts | ForEach-Object { $_[2] } | Measure-Object -Maximum).Maximum) }
        }
        $script:rangeChecks = @(); $script:overridden = @()
        function Walk($occurrences, $parentId, $parentWorld, $parentVisible, $parentSuppressed, $depth, $parentFlexible) {
            foreach ($o in $occurrences) {
                $id = if ($parentId -eq "root") { $o.Name } else { "$parentId/$($o.Name)" }
                $world = Cells $o.Transformation
                $local = Mul (InvRigid $parentWorld) $world
                $localDef = $null; try { $n = $o.NativeObject; if ($n) { $localDef = Cells $n.Transformation } } catch { }
                $defDev = $(if ($localDef) { MaxDiff $local $localDef } else { 0.0 })
                if ($defDev -gt 1e-6) { $script:overridden += [ordered]@{ id = $id; max_abs_cell_difference_cm = $defDev } }
                $visOwn = [bool]$o.Visible; $supOwn = [bool]$o.Suppressed
                $visEff = $parentVisible -and $visOwn; $supEff = $parentSuppressed -or $supOwn
                $det = Det3 $local
                if ($det -lt 0) { $script:warnings += "mirrored occurrence (det<0): $id" }
                $bom = $(try { [int]$o.BOMStructure } catch { $null })
                $flexible = $(try { [bool]$o.Flexible } catch { $null })
                $common = [ordered]@{ id = $id; name = $o.Name; parent_id = $parentId; depth = $depth; transform_local_cm = $local; transform_world_cm = $world; transform_local_definition_cm = $localDef
                    position_overridden_vs_definition = ($defDev -gt 1e-6); definition_difference_cm = $defDev; determinant = $det; mirrored = ($det -lt 0)
                    visible = $visOwn; visible_effective = $visEff; suppressed = $supOwn; suppressed_effective = $supEff; grounded = [bool]$o.Grounded; flexible = $flexible; parent_flexible = $parentFlexible
                    bom_structure = [ordered]@{ value = $bom; name = $(if ($bom -ne $null) { $bomNames[$bom] } else { $null }) }
                    active_model_state = $(try { $o.ActiveModelState } catch { $null }) }
                if ($supOwn) { $common.note = "suppressed: not traversed/exported"; $script:occs += $common; continue }
                if ($o.DefinitionDocumentType -eq $kAssembly) {
                    $common.kind = "assembly"; $common.document = $o.Definition.Document.FullFileName
                    $script:groups += $common
                    Walk $o.SubOccurrences $id $world $visEff $supEff ($depth + 1) $flexible
                } else {
                    $common.kind = "part"; $common.part_id = (Ensure-Part $o); $parts[$common.part_id].instance_count++
                    # sanity: definition RangeBox transformed by world vs Inventor's proxy RangeBox (exact for axis-aligned rotations)
                    try { $tb = Transform-Box $parts[$common.part_id].range_box_cm $world; $pb = Box $o.RangeBox; $dev = 0.0; for ($k = 0; $k -lt 3; $k++) { $dev = [Math]::Max($dev, [Math]::Max([Math]::Abs($tb.min[$k] - $pb.min[$k]), [Math]::Abs($tb.max[$k] - $pb.max[$k]))) }; $common.range_check_max_dev_cm = $dev; $script:rangeChecks += $dev } catch { }
                    $script:occs += $common
                }
            }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Walk $rootDef.Occurrences "root" $Identity $true $false 1 $false
        $walkSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $maxDev = $(if ($script:rangeChecks.Count) { ($script:rangeChecks | Measure-Object -Maximum).Maximum } else { $null })
        $checked = $script:rangeChecks.Count; $unmatched = @()
        $positional = $(try { $rootDef.RepresentationsManager.ActivePositionalRepresentation.Name } catch { $null })

        $leafCount = @($occs | Where-Object { $_.kind -eq "part" -and -not $_.suppressed }).Count
        $snapshot = [ordered]@{ schema = "vault-cad-tools native snapshot 1"; generated_at = Utc; inventor_version = $app.SoftwareVersion.DisplayVersion; inventor_build = $app.SoftwareVersion.BuildIdentifier
            assembly = [ordered]@{ document = $asm.FullFileName; sha256 = (Sha $NativeAssembly); length_units = $rootUnits; model_state = $(try { $rootDef.ModelStates.ActiveModelState.Name } catch { "n/a" }); source = $(if ($acq[$NativeAssembly.ToLowerInvariant()]) { $a = $acq[$NativeAssembly.ToLowerInvariant()]; [ordered]@{ vault_id = "28"; version_id = [string]$a.version_id; master_id = [string]$a.master_id; vault_path = $a.vault_path; native_sha256 = $a.sha256 } } else { $null }) }
            conventions = [ordered]@{ length_unit = "cm (Inventor API)"; matrices = "4x4 row-major, applied to column vectors, translation in last column; transform_world_cm is root-from-child as reported by Inventor for the instance (proxy context); transform_local_cm = inv(parent world) * world (parent-from-child); transform_local_definition_cm is the occurrence's transform inside its own sub-assembly definition"; axes = "native Inventor model axes as stored; no basis change applied"; walk = "instance tree (Occurrences then SubOccurrences proxies)" }
            cross_check = [ordered]@{ leaves_range_checked = $checked; max_range_box_deviation_cm = $maxDev; note = "definition RangeBox transformed by world vs proxy RangeBox; exact only for axis-aligned rotations"; instance_positions_overridden_vs_definition = $script:overridden; active_positional_representation = $positional; walk_seconds = $walkSeconds }
            counts = [ordered]@{ distinct_parts = $parts.Count; groups = $groups.Count; leaf_occurrences = $leafCount; suppressed_occurrences = @($occs | Where-Object suppressed).Count; mirrored_occurrences = @($occs | Where-Object mirrored).Count }
            warnings = $warnings; parts = @($parts.Values); groups = $groups; occurrences = $occs }
        $snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "native-snapshot.json") -Encoding UTF8

        # Adapter to the draft-1 contract (mm). Native up-axis is declared, not silently rotated.
        $basisToZUp = @(@(1.0,0.0,0.0,0.0),@(0.0,0.0,-1.0,0.0),@(0.0,1.0,0.0,0.0),@(0.0,0.0,0.0,1.0))  # rotate +90 deg about X: (x,y,z) -> (x,-z,y)
        $scene = [ordered]@{ schema_version = "draft-1"; id = "free-standing-enclosure-" + $snapshot.assembly.source.version_id; title = "Free Standing Enclosure (Vault file-version $($snapshot.assembly.source.version_id)) native snapshot"; units = "mm"
            coordinate_system = [ordered]@{ handedness = "right"; up_axis = "+Y"; origin = "native assembly origin of Free Standing Enclosure.iam"; note = "Transforms are in the native Inventor frame (Y up for this model). basis_to_z_up maps native (x,y,z) to a +Z-up frame as (x,-z,y); apply it once at the scene root if a Z-up scene is required." ; basis_to_z_up = $basisToZUp }
            source = [ordered]@{ kind = "autodesk-inventor-vault-snapshot"; vault_id = "28"; root_version_id = $snapshot.assembly.source.version_id; root_master_id = $snapshot.assembly.source.master_id; root_vault_path = $snapshot.assembly.source.vault_path; exporter = "windows/Export-PartAssets.ps1 on Inventor $($app.SoftwareVersion.DisplayVersion)"; qualification = "geometry/hierarchy snapshot; not a reviewed assembly procedure or stock inventory"; occurrence_id_scope = "snapshot-scoped occurrence paths (Inventor occurrence names); stable only within this snapshot" }
            parts = @(foreach ($p in $parts.Values) { [ordered]@{ id = $p.id; name = [IO.Path]::GetFileNameWithoutExtension($p.document); asset = [ordered]@{ path = $p.asset.path; format = "step"; units = $(if ($p.asset.step_length_unit) { $p.asset.step_length_unit } else { "undeclared-in-header; inspect file" }); sha256 = $p.asset.sha256 }; identifying_dimensions_mm = [ordered]@{ extent = @($p.range_box_cm.extent | ForEach-Object { $_ * 10 }) }; model_state = $p.model_state; bodies = $p.bodies; volume_mm3 = $(if ($p.volume_cm3 -ne $null) { $p.volume_cm3 * 1000 } else { $null }); bom_structure_default = $p.default_bom_structure.name; properties = $p.properties; source = $p.source } })
            assemblies = @([ordered]@{ id = "root"; parent_id = $null; transform = $Identity; document = $asm.FullFileName }) + @(foreach ($g in $groups) { [ordered]@{ id = $g.id; parent_id = $g.parent_id; transform = (ToMm $g.transform_local_cm); document = $g.document; visible = $g.visible; suppressed = $g.suppressed; bom_structure = $g.bom_structure.name; model_state = $g.active_model_state } })
            occurrences = @(foreach ($o in $occs) { if ($o.kind -ne "part") { continue }; [ordered]@{ id = $o.id; part_id = $o.part_id; parent_id = $o.parent_id; transform = (ToMm $o.transform_local_cm); transform_world = (ToMm $o.transform_world_cm); position_overridden_vs_definition = $o.position_overridden_vs_definition; parent_flexible = $o.parent_flexible; visible = $o.visible; visible_effective = $o.visible_effective; suppressed = $o.suppressed; grounded = $o.grounded; mirrored = $o.mirrored; bom_structure = $o.bom_structure.name; model_state = $o.active_model_state } }) }
        $scene | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "scene.json") -Encoding UTF8
        $inventory = [ordered]@{ schema_version = "draft-1"; scene = "scene.json"; status = "CAD instance counts with native BOM structure; NOT physical stock, purchase quantities or kit contents"
            items = @(foreach ($p in $parts.Values) { [ordered]@{ part_id = $p.id; cad_instances = $p.instance_count; bom_structure_default = $p.default_bom_structure.name; occurrence_bom_structures = @(($occs | Where-Object { $_.kind -eq "part" -and $_.part_id -eq $p.id } | ForEach-Object { $_.bom_structure.name }) | Sort-Object -Unique); part_number = $p.properties.part_number; description = $p.properties.description; material = $p.properties.material; vendor = $p.properties.vendor; required = $null; counted = $null } }) }
        $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "inventory-raw.json") -Encoding UTF8
        $files = [ordered]@{}; foreach ($f in Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File) { if ($f.Name -ne "export-receipt.json") { $files[$f.FullName.Substring($OutputDirectory.Length + 1) -replace '\\', '/'] = [ordered]@{ sha256 = (Sha $f.FullName); bytes = $f.Length } } }
        [ordered]@{ schema_version = 1; generated_at = Utc; exporter = "windows/Export-PartAssets.ps1"; inventor = "$($app.SoftwareVersion.DisplayVersion) build $($app.SoftwareVersion.BuildIdentifier)"; host = $env:COMPUTERNAME; assembly = $snapshot.assembly; counts = $snapshot.counts; cross_check = $snapshot.cross_check; warnings = $warnings; files = $files } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "export-receipt.json") -Encoding UTF8
        Write-Output ("distinct parts {0}, groups {1}, leaf occurrences {2}, suppressed {3}, mirrored {4}; range check on {5} leaves max deviation {6} cm; instance positions overridden vs definition: {7}; positional representation: {8}; walk {9}s" -f $parts.Count, $groups.Count, $leafCount, $snapshot.counts.suppressed_occurrences, $snapshot.counts.mirrored_occurrences, $checked, $maxDev, $script:overridden.Count, $positional, $walkSeconds)
        foreach ($ov in $script:overridden) { Write-Output ("  overridden: {0} (max cell diff {1} cm)" -f $ov.id, [Math]::Round($ov.max_abs_cell_difference_cm, 6)) }
        foreach ($g in $groups) { if ($g.flexible) { Write-Output "  flexible sub-assembly: $($g.id)" } }
        foreach ($p in $parts.Values) { Write-Output ("  {0,3} x {1,-60} bodies {2}/{3} vis {4}  bom {5,-10} pn '{6}'  step unit {7}" -f $p.instance_count, ([IO.Path]::GetFileName($p.document) + " [" + $p.model_state + "]"), $p.bodies.solid_bodies, $p.bodies.surface_bodies, $p.bodies.visible_solid_bodies, $p.default_bom_structure.name, $p.properties.part_number, $p.asset.step_length_unit) }
        if ($warnings.Count) { Write-Output "warnings: $($warnings -join '; ')" }
    } finally { $asm.Close($true) }
} catch {
    $errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    try { while ($app.Documents.Count -gt 0) { $app.Documents.Item($app.Documents.Count).Close($true) } } catch { }
    try { if ($dpm -and $previous) { foreach ($p in $dpm.DesignProjects) { if ($p.FullFileName -ieq $previous) { $p.Activate($false) } } }; if ($proj) { $proj.Remove() } } catch { Write-Output "Could not restore project list: $($_.Exception.Message)" }
    try { $app.Quit() } catch { }
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($app)
}
if ($errors.Count -gt 0) { exit 1 }
