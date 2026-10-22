<#
.SYNOPSIS
Export one STEP per distinct part geometry of a native assembly plus an occurrence/hierarchy manifest,
with strict provenance binding, fail-closed configuration guards and validated outputs.

.DESCRIPTION
Walks instance occurrences (including flexible subassembly proxies), derives parent-relative
transforms from Inventor's top-level-context world transforms, and cross-checks placements against
Inventor proxy bounds. Writes under -OutputDirectory (which must not exist or must be empty):
  assets/<part>.step             one STEP (local frame, AP214, no sketches) per distinct
                                  part document + model state; multibody parts stay one asset
  native-snapshot.json           raw Inventor data: cm, native axes, numeric enums, properties,
                                  verified native inputs (root, intermediate assemblies, parts)
  scene.json                     adapter to the mechanical-docs draft-1 contract: mm, 4x4 row-major
                                  matrices for column vectors, translation in the last column,
                                  parent@child, native up-axis DECLARED with a basis_to_z_up matrix
  inventory-raw.json             per-part CAD instance counts with native BOM structure; not stock
  export-receipt.json            status, session ownership and observed shutdown, guards, verified
                                  inputs, validation result, hashes of every other file

Supported subset (anything else is refused; a failing, null, empty or wrongly typed guard QUERY is also a refusal):
  parts and assemblies in their PRIMARY model state ("[Primary]"/"Master"/"Primary"; occurrence state ==
  document/definition state), master level of detail and master positional representation, rigid
  placements (determinant +1), iPart/iAssembly MEMBERS allowed, flexible sub-assemblies allowed.
  Refused: iPart/iAssembly factories, adaptive occurrences, substitute (LOD) occurrences, mirrored
  occurrences, non-master LOD or positional representation, unresolved references, documents not
  bound to the acquisition record (strict mode), undeterminable or ambiguous STEP length units.

Guards run before any asset is written except the STEP unit check, which can only run after the
translator has written the file: in that case the run is FAILED (receipt status) and the partial
output must not be consumed. Status is "complete" only when no error occurred, the semantic output
validation (Snapshot-Validation.ps1) passed and the shutdown was observed to succeed; otherwise the
exit code is 1. Occurrence ids are the snapshot-scoped occurrence paths.
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$Acquisition,
    [string]$Inventory,
    [switch]$AllowUnboundInputs,
    [ValidateSet(2, 3, 4, 5)][int]$ApplicationProtocolType = 3,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")
. (Join-Path $PSScriptRoot "Step-Units.ps1")
. (Join-Path $PSScriptRoot "Snapshot-Validation.ps1")

# ---- pre-flight (no Inventor yet) ----
if (-not (Test-Path -LiteralPath $NativeAssembly)) { throw "Assembly not found: $NativeAssembly" }
$NativeAssembly = (Resolve-Path -LiteralPath $NativeAssembly).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$acqJson = $null; $invJson = $null
if ($AllowUnboundInputs) {
    if ($Acquisition -or $Inventory) { throw "-AllowUnboundInputs cannot be combined with -Acquisition/-Inventory" }
} else {
    if (-not $Acquisition -or -not $Inventory) { throw "Strict mode needs -Acquisition and -Inventory (or -AllowUnboundInputs for fixtures without Vault provenance)" }
    foreach ($f in @($Acquisition, $Inventory)) { if (-not (Test-Path -LiteralPath $f)) { throw "Record not found: $f" } }
    $acqJson = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
    $invJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
    if (-not $acqJson.files -or -not $invJson.files) { throw "Acquisition/inventory records have no files" }
}
if (Test-Path -LiteralPath $OutputDirectory) {
    if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" }
} else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$assetsDir = Join-Path $OutputDirectory "assets"; New-Item -ItemType Directory -Path $assetsDir | Out-Null

$kPart = 12290; $kAssembly = 12291; $kFileBrowseIOMechanism = 13059; $stepTranslatorClsid = "{90AF7F40-0C01-11D5-8E83-0010B541CD80}"
$lengthUnitNames = @{ 11268 = "cm"; 11269 = "mm"; 11270 = "m"; 11271 = "micron"; 11272 = "in"; 11273 = "ft" }
$bomNames = @{ 51969 = "Default"; 51970 = "Normal"; 51971 = "Phantom"; 51972 = "Reference"; 51973 = "Purchased"; 51974 = "Inseparable"; 51975 = "Varies" }
$masterNames = @("Master", "[Primary]", "Primary")
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
$Identity = @(@(1.0,0.0,0.0,0.0),@(0.0,1.0,0.0,0.0),@(0.0,0.0,1.0,0.0),@(0.0,0.0,0.0,1.0))
function Prop($doc, $set, $name) { try { return $doc.PropertySets.Item($set).Item($name).Value } catch { return $null } }   # descriptive metadata: optional
function Safe($s) { ($s -replace '[\\/:*?"<>|]', '_') -replace '\s+', ' ' }
function Box($rb) { [ordered]@{ min = @($rb.MinPoint.X, $rb.MinPoint.Y, $rb.MinPoint.Z); max = @($rb.MaxPoint.X, $rb.MaxPoint.Y, $rb.MaxPoint.Z); extent = @(($rb.MaxPoint.X - $rb.MinPoint.X), ($rb.MaxPoint.Y - $rb.MinPoint.Y), ($rb.MaxPoint.Z - $rb.MinPoint.Z)) } }
function Sha-String($s) { $h = [Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').ToLowerInvariant() }
# Required guard queries fail CLOSED: an exception means the configuration is unknown and is refused.
function Require($what, [scriptblock]$query, [ValidateSet("bool", "string", "int")][string]$Kind = "bool") {
    # The RAW value is validated before any cast: [bool]$null is $false and "" -eq "" is $true, so a missing
    # or empty API result must never pass as "not a factory" or as "model states agree".
    $raw = $null
    try { $raw = & $query } catch { throw "Required guard query '$what' failed; unknown configuration refused: $($_.Exception.Message)" }
    if ($null -eq $raw) { throw "Required guard query '$what' returned null; unknown configuration refused" }
    if ($raw -is [array]) { throw "Required guard query '$what' returned a collection; unknown configuration refused" }
    switch ($Kind) {
        "bool"   { if ($raw -isnot [bool]) { throw "Required guard query '$what' returned '$raw' ($($raw.GetType().Name)), not a boolean; unknown configuration refused" }; return [bool]$raw }
        "string" { if ($raw -isnot [string] -or [string]::IsNullOrWhiteSpace($raw)) { throw "Required guard query '$what' returned an empty or non-string value ($($raw.GetType().Name)); unknown configuration refused" }; return [string]$raw }
        "int"    { if ($raw -isnot [int] -and $raw -isnot [long] -and $raw -isnot [int16] -and $raw -isnot [byte]) { throw "Required guard query '$what' returned '$raw' ($($raw.GetType().Name)), not an integer; unknown configuration refused" }; return [int]$raw }
    }
}

$session = Start-IsolatedInventor
$app = $session.App
Write-Output "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build)); ownership via $($session.OwnershipMethod)"
$project = $null; $errors = @(); $shutdown = $null; $validation = $null
$parts = [ordered]@{}; $groups = @(); $occs = @(); $warnings = @(); $inputs = @(); $inputMode = $(if ($AllowUnboundInputs) { "unbound (fixture)" } else { "strict acquisition binding" })
$vaultId = $(if ($invJson) { [string]$invJson.vault_id } else { $null }); $vaultName = $(if ($invJson -and $invJson.vault_name) { [string]$invJson.vault_name } else { $null })
$guards = [ordered]@{ output_directory_empty = $true; assets_no_preexisting_files = $true; inputs_bound_before_export = (-not $AllowUnboundInputs); unresolved_references_rejected = $true; unit_contexts_all_validated = $true; model_state_consistency_parts_and_assemblies = $true; factories_rejected_root_and_nested = $true; adaptive_substitute_rejected = $true; mirrored_rejected = $true; master_lod_and_positional_required = $true; model_states_primary_only = $true; guard_queries_fail_closed = $true; guard_values_validated_before_cast = $true }
$snapshotWritten = $false; $snapshot = $null; $leafCount = 0
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Write-Output "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry); activated by this run: $($project.Activated))"
    $translator = $app.ApplicationAddIns.ItemById($stepTranslatorClsid); if (-not $translator.Activated) { $translator.Activate() }
    $to = $app.TransientObjects
    Write-Output "Opening $NativeAssembly"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        $rootDef = $asm.ComponentDefinition
        $rootUnits = $lengthUnitNames[[int]$asm.UnitsOfMeasure.LengthUnits]
        # ---- bind every opened document BEFORE exporting anything ----
        if ($AllowUnboundInputs) {
            $missing = @(); foreach ($rd in @($asm) + @($asm.AllReferencedDocuments)) { foreach ($fd in $rd.File.ReferencedFileDescriptors) { if ($fd.ReferenceMissing) { $missing += $fd.FullFileName } } }
            if ($missing.Count -gt 0) { throw "Unresolved references: $($missing -join '; ')" }
            foreach ($d in @($asm) + @($asm.AllReferencedDocuments)) { $inputs += [ordered]@{ path = $d.FullFileName; kind = $(if ($d.DocumentType -eq $kAssembly) { "assembly" } else { "part" }); current_sha256 = (Sha $d.FullFileName); verified = $false; note = "no acquisition record (fixture)" } }
        } else {
            $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
            Write-Output "Bound $($inputs.Count) opened documents to acquisition/inventory ($(@($inputs | Where-Object { $_.kind -eq 'assembly' }).Count) assemblies, $(@($inputs | Where-Object { $_.kind -eq 'part' }).Count) parts)"
        }
        $inputByPath = @{}; foreach ($i in $inputs) { $inputByPath[$i.path.ToLowerInvariant()] = $i }
        # ---- root configuration guards (required) ----
        if (Require "root IsiAssemblyFactory" { $rootDef.IsiAssemblyFactory }) { throw "Unsupported: root assembly is an iAssembly factory" }
        $rootModelState = Require "root model state" { $rootDef.ModelStates.ActiveModelState.Name } -Kind string
        $positional = Require "root positional representation" { $rootDef.RepresentationsManager.ActivePositionalRepresentation.Name } -Kind string
        $rootLod = Require "root level of detail" { $rootDef.RepresentationsManager.ActiveLevelOfDetailRepresentation.Name } -Kind string
        if ($masterNames -notcontains $rootModelState) { throw "Unsupported: root model state '$rootModelState' (tested subset: primary model states only)" }
        if ($masterNames -notcontains $positional) { throw "Unsupported: root positional representation '$positional' (master required)" }
        if ($masterNames -notcontains $rootLod) { throw "Unsupported: root level of detail '$rootLod' (master required)" }

        function Part-Key($doc, $modelState) { $rel = $doc.FullFileName; if ($rel.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant())) { $rel = $rel.Substring($WorkspaceRoot.Length).TrimStart('\') }; return "$rel|$modelState" }
        function Ensure-Part($occ, $occId) {
            $doc = $occ.Definition.Document
            $cd = $doc.ComponentDefinition
            $docMs = Require "document model state of '$occId'" { $cd.ModelStates.ActiveModelState.Name } -Kind string
            $ms = Require "occurrence model state of '$occId'" { $occ.ActiveModelState } -Kind string
            if ($ms -ne $docMs) { throw "Unsupported: occurrence '$occId' uses model state '$ms' but the document's active state is '$docMs'" }
            if ($masterNames -notcontains $ms) { throw "Unsupported: occurrence '$occId' model state '$ms' (tested subset: primary model states only)" }
            if (Require "IsiPartFactory of '$occId'" { $cd.IsiPartFactory }) { throw "Unsupported: iPart factory $($doc.FullFileName) ('$occId')" }
            $isMember = Require "IsiPartMember of '$occId'" { $cd.IsiPartMember }
            $key = Part-Key $doc $ms
            if ($parts.Contains($key)) { return $key }
            $base = [IO.Path]::GetFileNameWithoutExtension($doc.FullFileName)
            $assetName = (Safe "$base`__$(Safe $ms)__$((Sha-String $key).Substring(0, 8))") + ".step"
            $assetPath = Join-Path $assetsDir $assetName
            if (Test-Path -LiteralPath $assetPath) { throw "Asset already exists, refusing to overwrite: $assetPath" }
            $bodies = 0; $solids = 0; $visible = 0; foreach ($b in $cd.SurfaceBodies) { $bodies++; $s = Require "IsSolid of a body in '$occId'" { $b.IsSolid }; if ($s) { $solids++; if ($b.Visible) { $visible++ } } }
            $ctx = $to.CreateTranslationContext(); $ctx.Type = $kFileBrowseIOMechanism
            $opts = $to.CreateNameValueMap()
            if ($translator.HasSaveCopyAsOptions($doc, $ctx, $opts)) { Set-MapValue $opts "ApplicationProtocolType" $ApplicationProtocolType; if ((Read-Map $opts).Contains("IncludeSketches")) { Set-MapValue $opts "IncludeSketches" $false } }
            $medium = $to.CreateDataMedium(); $medium.FileName = $assetPath
            $translator.SaveCopyAs($doc, $ctx, $opts, $medium)
            $lu = Get-StepLengthUnit $assetPath
            if (-not $lu.ok) { throw "STEP length unit of $assetName rejected: $($lu.reason)" }
            $inp = $inputByPath[$doc.FullFileName.ToLowerInvariant()]
            $parts[$key] = [ordered]@{ id = $key; document = $doc.FullFileName; model_state = $ms; document_model_state_count = (Require "model state count of '$occId'" { $cd.ModelStates.Count } -Kind int); display_name = $doc.DisplayName; is_ipart_member = $isMember
                asset = [ordered]@{ path = "assets/$assetName"; format = "step"; protocol = "AP$(@{2='203';3='214';4='203E2';5='242'}[$ApplicationProtocolType])"; sha256 = (Sha $assetPath); bytes = (Get-Item -LiteralPath $assetPath).Length; step_length_unit = $lu.unit; step_length_unit_detection = $lu; translator_options = (Read-Map $opts) }
                native_length_units = $lengthUnitNames[[int]$doc.UnitsOfMeasure.LengthUnits]; range_box_cm = (Box $cd.RangeBox)
                bodies = [ordered]@{ surface_bodies = $bodies; solid_bodies = $solids; visible_solid_bodies = $visible }
                volume_cm3 = $(try { [double]$cd.MassProperties.Volume } catch { $null })
                default_bom_structure = [ordered]@{ value = [int]$cd.BOMStructure; name = $bomNames[[int]$cd.BOMStructure] }
                properties = [ordered]@{ part_number = (Prop $doc "Design Tracking Properties" "Part Number"); description = (Prop $doc "Design Tracking Properties" "Description"); material = (Prop $doc "Design Tracking Properties" "Material"); stock_number = (Prop $doc "Design Tracking Properties" "Stock Number"); vendor = (Prop $doc "Design Tracking Properties" "Vendor"); manufacturer = (Prop $doc "Design Tracking Properties" "Manufacturer"); title = (Prop $doc "Inventor Summary Information" "Title"); category = (Prop $doc "Inventor Document Summary Information" "Category") }
                source = $(if ($inp -and $inp.verified) { [ordered]@{ vault_id = $vaultId; version_id = $inp.version_id; master_id = $inp.master_id; vault_path = $inp.vault_path; version = $inp.version; state = $inp.state; native_sha256 = $inp.acquisition_sha256; verified = $true } } else { [ordered]@{ verified = $false; current_sha256 = $(if ($inp) { $inp.current_sha256 } else { Sha $doc.FullFileName }); note = "not bound to a Vault acquisition record" } })
                instance_count = 0 }
            return $key
        }

        $script:rangeChecks = @(); $script:overridden = @()
        function Walk($occurrences, $parentId, $parentWorld, $parentVisible, $depth, $parentFlexible) {
            foreach ($o in $occurrences) {
                $id = if ($parentId -eq "root") { $o.Name } else { "$parentId/$($o.Name)" }
                $supOwn = Require "Suppressed of '$id'" { $o.Suppressed }
                if ($supOwn) { $script:occs += [ordered]@{ id = $id; name = $o.Name; parent_id = $parentId; depth = $depth; kind = "suppressed"; suppressed = $true; note = "suppressed: not traversed/exported" }; continue }
                if (Require "Adaptive of '$id'" { $o.Adaptive }) { throw "Unsupported: adaptive occurrence '$id'" }
                if (Require "IsSubstituteOccurrence of '$id'" { $o.IsSubstituteOccurrence }) { throw "Unsupported: substitute (LOD) occurrence '$id'" }
                $world = Cells $o.Transformation
                $local = Mul (InvRigid $parentWorld) $world
                $det = Det3 $local
                if ($det -lt 0) { throw "Unsupported: mirrored occurrence (negative determinant) '$id'" }
                $localDef = $null; try { $n = $o.NativeObject; if ($n) { $localDef = Cells $n.Transformation } } catch { }   # descriptive
                $defDev = $(if ($localDef) { MaxDiff $local $localDef } else { 0.0 })
                if ($defDev -gt 1e-6) { $script:overridden += [ordered]@{ id = $id; max_abs_cell_difference_cm = $defDev } }
                $visOwn = [bool]$o.Visible; $visEff = $parentVisible -and $visOwn
                $bom = $(try { [int]$o.BOMStructure } catch { $null })                                                     # descriptive
                $flexible = $(try { [bool]$o.Flexible } catch { $null })                                                   # descriptive
                $common = [ordered]@{ id = $id; name = $o.Name; parent_id = $parentId; depth = $depth; transform_local_cm = $local; transform_world_cm = $world; transform_local_definition_cm = $localDef
                    position_overridden_vs_definition = ($defDev -gt 1e-6); definition_difference_cm = $defDev; determinant = $det
                    visible = $visOwn; visible_effective = $visEff; grounded = [bool]$o.Grounded; flexible = $flexible; parent_flexible = $parentFlexible
                    bom_structure = [ordered]@{ value = $bom; name = $(if ($bom -ne $null) { $bomNames[$bom] } else { $null }) }
                    active_model_state = (Require "ActiveModelState of '$id'" { $o.ActiveModelState } -Kind string) }
                if ($o.DefinitionDocumentType -eq $kAssembly) {
                    $def = $o.Definition
                    if (Require "IsiAssemblyFactory of '$id'" { $def.IsiAssemblyFactory }) { throw "Unsupported: nested iAssembly factory '$id'" }
                    $lod = Require "ActiveLevelOfDetailRepresentation of '$id'" { $o.ActiveLevelOfDetailRepresentation } -Kind string
                    $pos = Require "ActivePositionalRepresentation of '$id'" { $o.ActivePositionalRepresentation } -Kind string
                    if ($masterNames -notcontains $lod) { throw "Unsupported: assembly occurrence '$id' uses level of detail '$lod'" }
                    if ($masterNames -notcontains $pos) { throw "Unsupported: assembly occurrence '$id' uses positional representation '$pos'" }
                    $defMs = Require "definition model state of '$id'" { $def.ModelStates.ActiveModelState.Name } -Kind string
                    if ($common.active_model_state -ne $defMs) { throw "Unsupported: assembly occurrence '$id' model state '$($common.active_model_state)' differs from its definition's active state '$defMs'" }
                    if ($masterNames -notcontains $common.active_model_state) { throw "Unsupported: assembly occurrence '$id' model state '$($common.active_model_state)' (tested subset: primary model states only)" }
                    $common.kind = "assembly"; $common.document = $def.Document.FullFileName; $common.level_of_detail = $lod; $common.positional_representation = $pos
                    $common.is_iassembly_member = (Require "IsiAssemblyMember of '$id'" { $def.IsiAssemblyMember })
                    $script:groups += $common
                    Walk $o.SubOccurrences $id $world $visEff ($depth + 1) $flexible
                } else {
                    $common.kind = "part"; $common.part_id = (Ensure-Part $o $id); $parts[$common.part_id].instance_count++
                    try { $tb = Transform-Box $parts[$common.part_id].range_box_cm $world; $pb = Box $o.RangeBox; $dev = 0.0; for ($k = 0; $k -lt 3; $k++) { $dev = [Math]::Max($dev, [Math]::Max([Math]::Abs($tb.min[$k] - $pb.min[$k]), [Math]::Abs($tb.max[$k] - $pb.max[$k]))) }; $common.range_check_max_dev_cm = $dev; $script:rangeChecks += $dev } catch { }
                    $script:occs += $common
                }
            }
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Walk $rootDef.Occurrences "root" $Identity $true 1 $false
        $walkSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        $maxDev = $(if ($script:rangeChecks.Count) { ($script:rangeChecks | Measure-Object -Maximum).Maximum } else { $null })
        $rootInput = $inputByPath[$NativeAssembly.ToLowerInvariant()]
        $leafCount = @($occs | Where-Object { $_.kind -eq "part" }).Count
        $rootName = [IO.Path]::GetFileNameWithoutExtension($NativeAssembly)
        $snapshot = [ordered]@{ schema = "vault-cad-tools native snapshot 3"; generated_at = Utc; inventor_version = $session.Version; inventor_build = $session.Build; host = $env:COMPUTERNAME
            supported_subset = "primary model states only, occurrence == document/definition state; master LOD and positional representation; rigid placements; flexible sub-assemblies and iPart/iAssembly members allowed; factories/adaptive/substitute/mirrored refused; guard queries fail closed and their raw values are validated before any cast"
            assembly = [ordered]@{ document = $asm.FullFileName; sha256 = (Sha $NativeAssembly); length_units = $rootUnits; model_state = $rootModelState; positional_representation = $positional; level_of_detail = $rootLod
                source = $(if ($rootInput -and $rootInput.verified) { [ordered]@{ vault_id = $vaultId; vault_name = $vaultName; version_id = $rootInput.version_id; master_id = $rootInput.master_id; vault_path = $rootInput.vault_path; version = $rootInput.version; state = $rootInput.state; native_sha256 = $rootInput.acquisition_sha256 } } else { [ordered]@{ verified = $false; note = "no acquisition record (fixture)" } }) }
            input_binding = [ordered]@{ mode = $inputMode; opened_documents = $inputs.Count; verified = @($inputs | Where-Object verified).Count; inputs = $inputs }
            conventions = [ordered]@{ length_unit = "cm (Inventor API)"; matrices = "4x4 row-major, applied to column vectors, translation in last column; transform_world_cm is root-from-child as reported by Inventor for the instance (proxy context); transform_local_cm = inv(parent world) * world (parent-from-child); transform_local_definition_cm is the occurrence's transform inside its own sub-assembly definition"; axes = "native Inventor model axes as stored; no basis change applied"; walk = "instance tree (Occurrences then SubOccurrences proxies)" }
            cross_check = [ordered]@{ leaves_range_checked = $script:rangeChecks.Count; max_range_box_deviation_cm = $maxDev; note = "definition RangeBox transformed by world vs proxy RangeBox; exact only for axis-aligned rotations"; instance_positions_overridden_vs_definition = $script:overridden; walk_seconds = $walkSeconds }
            guards = $guards
            counts = [ordered]@{ distinct_parts = $parts.Count; groups = $groups.Count; leaf_occurrences = $leafCount; suppressed_occurrences = @($occs | Where-Object { $_.kind -eq "suppressed" }).Count; mirrored_occurrences = 0 }
            warnings = $warnings; parts = @($parts.Values); groups = $groups; occurrences = $occs }
        $snapshot | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "native-snapshot.json") -Encoding UTF8

        $basisToZUp = @(@(1.0,0.0,0.0,0.0),@(0.0,0.0,-1.0,0.0),@(0.0,1.0,0.0,0.0),@(0.0,0.0,0.0,1.0))  # (x,y,z) -> (x,-z,y)
        $sceneId = (Safe $rootName) -replace ' ', '-'; if ($snapshot.assembly.source.version_id) { $sceneId += "-v" + $snapshot.assembly.source.version_id }
        $scene = [ordered]@{ schema_version = "draft-1"; id = $sceneId; title = "$rootName native snapshot$(if ($snapshot.assembly.source.version_id) { " (Vault file-version $($snapshot.assembly.source.version_id))" })"; units = "mm"
            coordinate_system = [ordered]@{ handedness = "right"; up_axis = "+Y"; origin = "native assembly origin of $rootName"; note = "Transforms are in the native Inventor frame. basis_to_z_up maps native (x,y,z) to a +Z-up frame as (x,-z,y); apply it once at the scene root if a Z-up scene is required."; basis_to_z_up = $basisToZUp }
            source = [ordered]@{ kind = "autodesk-inventor-vault-snapshot"; vault_id = $vaultId; vault_name = $vaultName; root_version_id = $snapshot.assembly.source.version_id; root_master_id = $snapshot.assembly.source.master_id; root_vault_path = $snapshot.assembly.source.vault_path; input_binding = $inputMode; exporter = "windows/Export-PartAssets.ps1 on Inventor $($session.Version)"; qualification = "geometry/hierarchy snapshot; not a reviewed assembly procedure or stock inventory"; occurrence_id_scope = "snapshot-scoped occurrence paths (Inventor occurrence names); stable only within this snapshot" }
            parts = @(foreach ($p in $parts.Values) { [ordered]@{ id = $p.id; name = [IO.Path]::GetFileNameWithoutExtension($p.document); asset = [ordered]@{ path = $p.asset.path; format = "step"; units = $p.asset.step_length_unit; sha256 = $p.asset.sha256 }; identifying_dimensions_mm = [ordered]@{ extent = @($p.range_box_cm.extent | ForEach-Object { $_ * 10 }) }; model_state = $p.model_state; bodies = $p.bodies; volume_mm3 = $(if ($p.volume_cm3 -ne $null) { $p.volume_cm3 * 1000 } else { $null }); bom_structure_default = $p.default_bom_structure.name; properties = $p.properties; source = $p.source } })
            assemblies = @([ordered]@{ id = "root"; parent_id = $null; transform = $Identity; document = $asm.FullFileName }) + @(foreach ($g in $groups) { [ordered]@{ id = $g.id; parent_id = $g.parent_id; transform = (ToMm $g.transform_local_cm); document = $g.document; visible = $g.visible; flexible = $g.flexible; positional_representation = $g.positional_representation; bom_structure = $g.bom_structure.name; model_state = $g.active_model_state } })
            occurrences = @(foreach ($o in $occs) { if ($o.kind -ne "part") { continue }; [ordered]@{ id = $o.id; part_id = $o.part_id; parent_id = $o.parent_id; transform = (ToMm $o.transform_local_cm); transform_world = (ToMm $o.transform_world_cm); position_overridden_vs_definition = $o.position_overridden_vs_definition; parent_flexible = $o.parent_flexible; visible = $o.visible; visible_effective = $o.visible_effective; grounded = $o.grounded; bom_structure = $o.bom_structure.name; model_state = $o.active_model_state } }) }
        $scene | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory "scene.json") -Encoding UTF8
        # NB: $Inventory is the input-record PARAMETER (case-insensitive); the output object has its own name.
        $inventoryOutput = [ordered]@{ schema_version = "draft-1"; scene = "scene.json"; status = "CAD instance counts with native BOM structure; NOT physical stock, purchase quantities or kit contents"
            items = @(foreach ($p in $parts.Values) { [ordered]@{ part_id = $p.id; cad_instances = [int]$p.instance_count; bom_structure_default = $p.default_bom_structure.name; occurrence_bom_structures = @(($occs | Where-Object { $_.kind -eq "part" -and $_.part_id -eq $p.id } | ForEach-Object { $_.bom_structure.name }) | Sort-Object -Unique); part_number = $p.properties.part_number; description = $p.properties.description; material = $p.properties.material; vendor = $p.properties.vendor; required = $null; counted = $null } }) }
        $inventoryOutput | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "inventory-raw.json") -Encoding UTF8
        $snapshotWritten = $true
        # ---- semantic validation of what was just written (receipt not yet present) ----
        $validation = Test-SnapshotOutputs -Directory $OutputDirectory -ExpectParts $parts.Count -ExpectOccurrences $leafCount
        if (-not $validation.ok) { throw "Output validation failed: $($validation.failures -join '; ')" }
        Write-Output ("distinct parts {0}, groups {1}, leaf occurrences {2}, suppressed {3}; range check on {4} leaves max deviation {5} cm; instance positions overridden vs definition: {6}; root model state {7}, positional {8}, LOD {9}; walk {10}s; validation ok" -f $parts.Count, $groups.Count, $leafCount, $snapshot.counts.suppressed_occurrences, $script:rangeChecks.Count, $maxDev, $script:overridden.Count, $rootModelState, $positional, $rootLod, $walkSeconds)
        foreach ($g in $groups) { if ($g.flexible) { Write-Output "  flexible sub-assembly: $($g.id)" } }
        Write-Output ("  asset units: " + ((@($parts.Values | ForEach-Object { $_.asset.step_length_unit }) | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress) notes=$($shutdown.Notes -join ' | ')" }
    Write-Output "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded); observed $($shutdown.Observed | ConvertTo-Json -Compress)$(if ($shutdown.Notes) { '; notes: ' + ($shutdown.Notes -join ' | ') })"
}
function Write-Receipt($status) {
    $files = [ordered]@{}; foreach ($f in Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File) { if ($f.Name -ne "export-receipt.json") { $files[$f.FullName.Substring($OutputDirectory.Length + 1) -replace '\\', '/'] = [ordered]@{ sha256 = (Sha $f.FullName); bytes = $f.Length } } }
    [ordered]@{ schema_version = 3; generated_at = Utc; exporter = "windows/Export-PartAssets.ps1"; status = $status; errors = $errors
        inventor = "$($session.Version) build $($session.Build)"; host = $env:COMPUTERNAME; interactive_desktop = [Environment]::UserInteractive
        session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; started_at = $session.StartedAt.ToString("o"); pre_existing_inventor_pids = $session.PreExistingPids; shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; attempted = $shutdown.Attempted; observed = $shutdown.Observed; unexpected_survivors = @($shutdown.UnexpectedSurvivors); notes = @($shutdown.Notes) } }
        project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $shutdown.ProjectEntryRemoved; entry_preserved = $shutdown.ProjectEntryPreserved; previous_active = $project.PreviousActive; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
        input_binding = [ordered]@{ mode = $inputMode; opened_documents = $inputs.Count; verified = @($inputs | Where-Object verified).Count; inputs = $inputs }
        guards = $guards; validation = $(if ($validation) { [ordered]@{ ok = $validation.ok; failures = $validation.failures; summary = $validation.summary } } else { [ordered]@{ ok = $false; failures = @("validation did not run") } })
        assembly = $(if ($snapshotWritten) { $snapshot.assembly } else { @{ document = $NativeAssembly } }); counts = $(if ($snapshotWritten) { $snapshot.counts } else { $null }); cross_check = $(if ($snapshotWritten) { $snapshot.cross_check } else { $null }); warnings = $warnings; files = $files } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "export-receipt.json") -Encoding UTF8
}
$status = $(if ($errors.Count -eq 0 -and $snapshotWritten -and $validation -and $validation.ok -and $shutdown.Succeeded) { "complete" } else { "FAILED" })
Write-Receipt $status
if ($status -eq "complete") {
    # final check with the receipt present: every asset listed and hashed as recorded
    $final = Test-SnapshotOutputs -Directory $OutputDirectory -ExpectParts $parts.Count -ExpectOccurrences $leafCount -VerifyHashes
    if (-not $final.ok) { $errors += "post-receipt validation failed: $($final.failures -join '; ')"; $validation = $final; $status = "FAILED"; Write-Receipt $status }
}
Write-Output "Receipt status: $status"
if ($status -ne "complete") { exit 1 }
