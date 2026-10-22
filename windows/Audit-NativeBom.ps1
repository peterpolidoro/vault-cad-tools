<#
.SYNOPSIS
READ-ONLY audit of the native Inventor bill of materials of an acquired assembly snapshot: BOM views
and rows (structured, parts-only, model data), virtual components, BOM structure, suppressed /
excluded / reference instances, purchased-part body counts (kit boundaries) and quantity definitions.

.DESCRIPTION
    & .\windows\Audit-NativeBom.ps1 -NativeAssembly IAM -WorkspaceRoot MIRROR -OutputDirectory NEW `
        -Acquisition acquisition.json -Inventory dependency-inventory.json

Nothing is saved. Documents are opened invisibly in an owned Inventor instance (Inventor-Session.ps1),
every opened document is bound to the acquisition record before any data is read, the structured and
parts-only BOM views are enabled IN MEMORY ONLY when the stored document has them disabled (recorded
per document as `enabled_in_memory_only`), all documents are closed with SkipSave, and afterwards every
acquired file is re-hashed: `inputs_unchanged_after_run` must be true for the audit to be `complete`.

Quantities are recorded as the API reports them: `item_quantity` (integer count of the row at its
level), `total_quantity` (the API's string, which carries units for length/parameter quantities),
and per component definition the BOM quantity `base_units`, `unit_quantity` and evaluated base
quantity. None of these is a purchase quantity or stock.

Outputs under -OutputDirectory (must not exist or be empty):
  bom-rows.json / bom-rows.csv      every row of every view of every assembly document, flattened
  bom-views.json                    per assembly document: stored view flags, in-memory enablement, row counts
  occurrence-bom-flags.json         every instance in the tree: BOM structure, suppressed, excluded, reference,
                                    visible, enabled, pattern element, definition kind, model state
  virtual-components.json           rows/definitions that are virtual components (no file behind them)
  purchased-parts-bodies.json       every part: BOM structure, whether it is Purchased/Inseparable, whether it is
                                    multi-body, solid body counts, visibility and body names (kit boundary evidence);
                                    the Vendor iProperty is recorded but is not a classifier
  audit-receipt.json                session, observed shutdown, bound inputs, post-run hash check, counts
#>
param(
    [Parameter(Mandatory = $true)][string]$NativeAssembly,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Acquisition,
    [Parameter(Mandatory = $true)][string]$Inventory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]*$')][string]$ProjectName = "vault-cad-exporter",
    [string]$TemplateProject = "$env:PUBLIC\Documents\Autodesk\Inventor 2025\Default.ipj"
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Inventor-Session.ps1")

foreach ($f in @($NativeAssembly, $Acquisition, $Inventory)) { if (-not (Test-Path -LiteralPath $f)) { throw "Not found: $f" } }
$NativeAssembly = (Resolve-Path -LiteralPath $NativeAssembly).Path
$WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$acqJson = Get-Content -LiteralPath $Acquisition -Raw | ConvertFrom-Json
$invJson = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json
if (-not $acqJson.files -or -not $invJson.files) { throw "Acquisition/inventory records have no files" }
if (Test-Path -LiteralPath $OutputDirectory) { if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) { throw "Refusing non-empty output directory: $OutputDirectory" } } else { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

$kPart = 12290; $kAssembly = 12291
$bomNames = @{ 51969 = "Default"; 51970 = "Normal"; 51971 = "Phantom"; 51972 = "Reference"; 51973 = "Purchased"; 51974 = "Inseparable"; 51975 = "Varies" }
$viewNames = @{ 62465 = "ModelData"; 62466 = "Structured"; 62467 = "PartsOnly" }
$defKinds = @{ 83886592 = "part"; 100663808 = "assembly"; 100673280 = "weldment"; 100675072 = "virtual"; 150995200 = "sheet_metal" }
function Utc { [DateTime]::UtcNow.ToString("o") }
function Sha($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Rel($p) { if ($p -and $p.ToLowerInvariant().StartsWith($WorkspaceRoot.ToLowerInvariant())) { return $p.Substring($WorkspaceRoot.Length).TrimStart('\') }; return $p }
function Try-Get([scriptblock]$q) { try { return (& $q) } catch { return $null } }
function Prop($holder, $set, $name) { try { return $holder.PropertySets.Item($set).Item($name).Value } catch { return $null } }
function CustomProps($holder) {
    # "Inventor User Defined Properties": every custom iProperty, values as strings (dates/numbers formatted by .NET)
    $r = [ordered]@{}
    try { $set = $holder.PropertySets.Item("Inventor User Defined Properties"); for ($i = 1; $i -le $set.Count; $i++) { $p = $set.Item($i); $r[[string]$p.Name] = $(try { [string]$p.Value } catch { $null }) } } catch { }
    return $r
}
function Props($holder) { [ordered]@{ part_number = (Prop $holder "Design Tracking Properties" "Part Number"); description = (Prop $holder "Design Tracking Properties" "Description"); stock_number = (Prop $holder "Design Tracking Properties" "Stock Number"); vendor = (Prop $holder "Design Tracking Properties" "Vendor"); manufacturer = (Prop $holder "Design Tracking Properties" "Manufacturer"); material = (Prop $holder "Design Tracking Properties" "Material"); title = (Prop $holder "Inventor Summary Information" "Title"); custom = (CustomProps $holder) } }
function Quantity($def) {
    $q = Try-Get { $def.BOMQuantity }
    if ($null -eq $q) { return [ordered]@{ available = $false } }
    [ordered]@{ available = $true; base_units = (Try-Get { [string]$q.BaseUnits }); unit_quantity = (Try-Get { [string]$q.UnitQuantity }); evaluated_base_quantity = (Try-Get { [double]$q.GetEvaluatedBaseQuantity() }) }
}
function Definition-Record($def) {
    $type = [int](Try-Get { $def.Type })
    $kind = $(if ($defKinds.ContainsKey($type)) { $defKinds[$type] } else { "other:$type" })
    $doc = $(if ($kind -ne "virtual") { Try-Get { $def.Document } } else { $null })
    $holder = $(if ($doc) { $doc } else { $def })
    [ordered]@{ kind = $kind; document = $(if ($doc) { Rel $doc.FullFileName } else { $null }); display_name = (Try-Get { [string]$def.DisplayName }); definition_bom_structure = $(try { $v = [int]$def.BOMStructure; [ordered]@{ value = $v; name = $bomNames[$v] } } catch { $null })
        model_state = (Try-Get { [string]$def.ModelStates.ActiveModelState.Name }); properties = (Props $holder); quantity = (Quantity $def)
        surface_bodies = (Try-Get { [int]$def.SurfaceBodies.Count }) }
}

$session = Start-IsolatedInventor
$app = $session.App
Write-Output "Owned Inventor instance pid $($session.Pid) ($($session.Version) build $($session.Build))"
$project = $null; $errors = @(); $shutdown = $null; $inputs = @(); $rows = @(); $views = @(); $occFlags = @(); $virtuals = @(); $purchased = @(); $postCheck = $null
try {
    $project = Use-TemporaryProject $app (Join-Path $WorkspaceRoot "$ProjectName.ipj") $TemplateProject
    Write-Output "Project: $($project.Active) (entry pre-existed: $($project.EntryPreExisted); added: $($project.AddedEntry))"
    $asm = $app.Documents.Open($NativeAssembly, $false)
    try {
        $inputs = Confirm-AcquiredInputs $asm $acqJson $invJson
        Write-Output "Bound $($inputs.Count) opened documents to the acquisition record"
        $inputByPath = @{}; foreach ($i in $inputs) { $inputByPath[$i.path.ToLowerInvariant()] = $i }
        function Source($path) { $i = $inputByPath[$path.ToLowerInvariant()]; if ($i) { [ordered]@{ version_id = $i.version_id; master_id = $i.master_id; vault_path = $i.vault_path; version = $i.version; state = $i.state } } else { $null } }

        # ---- instance tree: BOM-relevant flags for every occurrence ----
        function Walk($occurrences, $parentId, $depth) {
            foreach ($o in $occurrences) {
                $id = if ($parentId -eq "root") { $o.Name } else { "$parentId/$($o.Name)" }
                $def = Try-Get { $o.Definition }
                $type = [int](Try-Get { $def.Type }); $kind = $(if ($defKinds.ContainsKey($type)) { $defKinds[$type] } else { "other:$type" })
                $doc = $(if ($kind -ne "virtual") { Try-Get { $def.Document } } else { $null })
                $bs = Try-Get { [int]$o.BOMStructure }
                $script:occFlags += [ordered]@{ id = $id; parent_id = $parentId; depth = $depth; definition_kind = $kind; document = $(if ($doc) { Rel $doc.FullFileName } else { $null }); source = $(if ($doc) { Source $doc.FullFileName } else { $null })
                    bom_structure = [ordered]@{ value = $bs; name = $(if ($null -ne $bs) { $bomNames[$bs] } else { $null }) }
                    suppressed = (Try-Get { [bool]$o.Suppressed }); excluded = (Try-Get { [bool]$o.Excluded }); reference = (Try-Get { [bool]$o.Reference }); visible = (Try-Get { [bool]$o.Visible }); enabled = (Try-Get { [bool]$o.Enabled })
                    is_pattern_element = (Try-Get { [bool]$o.IsPatternElement }); flexible = (Try-Get { [bool]$o.Flexible }); grounded = (Try-Get { [bool]$o.Grounded }); active_model_state = (Try-Get { [string]$o.ActiveModelState })
                    design_view = (Try-Get { [string]$o.ActiveDesignViewRepresentation }); level_of_detail = (Try-Get { [string]$o.ActiveLevelOfDetailRepresentation })
                    constraints = (Try-Get { [int]$o.Constraints.Count }); constraint_types = @(Try-Get { for ($ci = 1; $ci -le $o.Constraints.Count; $ci++) { [int]$o.Constraints.Item($ci).Type } }); joints = (Try-Get { [int]$o.Joints.Count }) }
                if ($kind -eq "virtual") { $script:virtuals += [ordered]@{ where = "occurrence"; id = $id; definition = (Definition-Record $def) } }
                if (-not (Try-Get { [bool]$o.Suppressed }) -and $kind -in @("assembly", "weldment")) { Walk $o.SubOccurrences $id ($depth + 1) }
            }
        }
        Walk $asm.ComponentDefinition.Occurrences "root" 1
        Write-Output "Instance tree: $($occFlags.Count) occurrences ($(@($occFlags | Where-Object suppressed).Count) suppressed, $(@($occFlags | Where-Object reference).Count) reference, $(@($occFlags | Where-Object excluded).Count) excluded, $(@($occFlags | Where-Object { $_.definition_kind -eq 'virtual' }).Count) virtual)"

        # ---- BOM views and rows for every assembly document ----
        $assemblyDocs = @($asm) + @($asm.AllReferencedDocuments | Where-Object { $_.DocumentType -eq $kAssembly })
        function Row-Record($row, $docRel, $viewName, $parentItem, $level) {
            $defs = @(); try { for ($i = 1; $i -le $row.ComponentDefinitions.Count; $i++) { $defs += Definition-Record $row.ComponentDefinitions.Item($i) } } catch { $defs += [ordered]@{ kind = "unreadable"; error = $_.Exception.Message } }
            $occs = @(); try { for ($i = 1; $i -le $row.ComponentOccurrences.Count; $i++) { $oc = $row.ComponentOccurrences.Item($i); $occs += [ordered]@{ name = (Try-Get { [string]$oc.Name }); bom_structure = (Try-Get { $bomNames[[int]$oc.BOMStructure] }); suppressed = (Try-Get { [bool]$oc.Suppressed }); excluded = (Try-Get { [bool]$oc.Excluded }); reference = (Try-Get { [bool]$oc.Reference }); visible = (Try-Get { [bool]$oc.Visible }) } } } catch { }
            $bs = Try-Get { [int]$row.BOMStructure }
            $fd = Try-Get { $row.ReferencedFileDescriptor }
            $rec = [ordered]@{ document = $docRel; view = $viewName; level = $level; parent_item = $parentItem; item_number = (Try-Get { [string]$row.ItemNumber }); item_quantity = (Try-Get { [int]$row.ItemQuantity }); total_quantity = (Try-Get { [string]$row.TotalQuantity }); total_quantity_overridden = (Try-Get { [bool]$row.TotalQuantityOverridden })
                bom_structure = [ordered]@{ value = $bs; name = $(if ($null -ne $bs) { $bomNames[$bs] } else { $null }) }; merged = (Try-Get { [bool]$row.Merged }); promoted = (Try-Get { [bool]$row.Promoted }); rolled_up = (Try-Get { [bool]$row.RolledUp })
                referenced_file = $(if ($fd) { [ordered]@{ path = (Rel (Try-Get { [string]$fd.FullFileName })); missing = (Try-Get { [bool]$fd.ReferenceMissing }) } } else { $null }); is_virtual = (@($defs | Where-Object { $_.kind -eq "virtual" }).Count -gt 0)
                component_definitions = $defs; component_occurrences = $occs; source = $(if ($fd -and (Try-Get { $fd.FullFileName })) { Source $fd.FullFileName } else { $null }) }
            $script:rows += $rec
            if ($rec.is_virtual) { $script:virtuals += [ordered]@{ where = "bom_row"; document = $docRel; view = $viewName; item_number = $rec.item_number; item_quantity = $rec.item_quantity; definitions = $defs } }
            try { $children = $row.ChildRows; if ($children) { for ($i = 1; $i -le $children.Count; $i++) { Row-Record $children.Item($i) $docRel $viewName $rec.item_number ($level + 1) } } } catch { }
        }
        foreach ($d in $assemblyDocs) {
            $docRel = Rel $d.FullFileName
            $bom = $d.ComponentDefinition.BOM
            $stored = [ordered]@{ structured_view_enabled = (Try-Get { [bool]$bom.StructuredViewEnabled }); parts_only_view_enabled = (Try-Get { [bool]$bom.PartsOnlyViewEnabled }); structured_view_first_level_only = (Try-Get { [bool]$bom.StructuredViewFirstLevelOnly }); hide_suppressed_components_in_bom = (Try-Get { [bool]$bom.HideSuppressedComponentsInBOM }); requires_update = (Try-Get { [bool]$bom.RequiresUpdate }); parts_only_numbering_scheme = (Try-Get { [int]$bom.PartsOnlyViewNumberingScheme }) }
            $enabledInMemory = @()
            if (-not $stored.structured_view_enabled) { try { $bom.StructuredViewEnabled = $true; $enabledInMemory += "structured" } catch { $errors += "$docRel : enabling structured view: $($_.Exception.Message)" } }
            if (-not $stored.parts_only_view_enabled) { try { $bom.PartsOnlyViewEnabled = $true; $enabledInMemory += "parts_only" } catch { $errors += "$docRel : enabling parts-only view: $($_.Exception.Message)" } }
            $viewRecs = @()
            for ($v = 1; $v -le $bom.BOMViews.Count; $v++) {
                $view = $bom.BOMViews.Item($v); $vt = [int](Try-Get { $view.ViewType }); $vn = $(if ($viewNames.ContainsKey($vt)) { $viewNames[$vt] } else { "view:$vt" })
                $before = $rows.Count
                try { for ($r = 1; $r -le $view.BOMRows.Count; $r++) { Row-Record $view.BOMRows.Item($r) $docRel $vn $null 1 } } catch { $errors += "$docRel / $vn : rows: $($_.Exception.Message)" }
                $viewRecs += [ordered]@{ view = $vn; name = (Try-Get { [string]$view.Name }); model_state_member = (Try-Get { [string]$view.ModelStateMemberName }); rows_recorded = ($rows.Count - $before) }
            }
            $views += [ordered]@{ document = $docRel; source = (Source $d.FullFileName); stored_flags = $stored; enabled_in_memory_only = $enabledInMemory; views = $viewRecs; model_state = (Try-Get { [string]$d.ComponentDefinition.ModelStates.ActiveModelState.Name }) }
            Write-Output ("  {0}: views {1}; rows {2}; enabled in memory: {3}" -f $docRel, (($viewRecs | ForEach-Object { $_.view }) -join '/'), (($viewRecs | ForEach-Object { $_.rows_recorded }) -join '/'), $(if ($enabledInMemory) { $enabledInMemory -join ',' } else { 'none' }))
        }

        # ---- purchased parts and body counts (kit boundary evidence) ----
        foreach ($d in @($asm.AllReferencedDocuments | Where-Object { $_.DocumentType -eq $kPart })) {
            $cd = $d.ComponentDefinition; $bs = Try-Get { [int]$cd.BOMStructure }; $p = Props $d
            $bodies = @(); try { for ($b = 1; $b -le $cd.SurfaceBodies.Count; $b++) { $body = $cd.SurfaceBodies.Item($b); $bodies += [ordered]@{ name = (Try-Get { [string]$body.Name }); solid = (Try-Get { [bool]$body.IsSolid }); visible = (Try-Get { [bool]$body.Visible }); faces = (Try-Get { [int]$body.Faces.Count }) } } } catch { }
            # Kit-boundary evidence is the body structure of the part, not the vendor text: the Vendor iProperty here
            # names the in-house shop for fabricated parts as well, so it is recorded but never used as a classifier.
            $solidCount = @($bodies | Where-Object solid).Count
            $purchased += [ordered]@{ document = (Rel $d.FullFileName); source = (Source $d.FullFileName); bom_structure = [ordered]@{ value = $bs; name = $(if ($null -ne $bs) { $bomNames[$bs] } else { $null }) }
                bom_structure_purchased_or_inseparable = ($bs -in @(51973, 51974)); multi_body = ($solidCount -gt 1); properties = $p; quantity = (Quantity $cd)
                bodies_total = $bodies.Count; solid_bodies = $solidCount; visible_solid_bodies = @($bodies | Where-Object { $_.solid -and $_.visible }).Count; hidden_solid_bodies = @($bodies | Where-Object { $_.solid -and -not $_.visible }).Count; bodies = $bodies }
        }
        Write-Output "Parts: $($purchased.Count) ($(@($purchased | Where-Object bom_structure_purchased_or_inseparable).Count) with Purchased/Inseparable BOM structure, $(@($purchased | Where-Object multi_body).Count) multi-body); BOM rows recorded: $($rows.Count); virtual components: $($virtuals.Count)"
    } finally { try { $asm.Close($true) } catch { $errors += "assembly close: $($_.Exception.Message)" } }
} catch {
    $errors += $_.Exception.Message; Write-Output "ERROR: $($_.Exception.Message)"; if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
} finally {
    $shutdown = Stop-IsolatedInventor $session $project
    if (-not $shutdown.Succeeded) { $errors += "shutdown not observed as complete: $($shutdown.Observed | ConvertTo-Json -Compress)" }
    Write-Output "Shutdown: pid $($shutdown.Pid) exited=$($shutdown.Exited) succeeded=$($shutdown.Succeeded)"
}
# ---- post-run integrity: every acquired file must still hash as acquired ----
$changed = @(); $checked = 0
foreach ($a in $acqJson.files) { if (Test-Path -LiteralPath $a.local_path) { $checked++; if ((Sha $a.local_path) -ne [string]$a.sha256) { $changed += $a.local_path } } }
$postCheck = [ordered]@{ files_checked = $checked; files_changed = $changed; inputs_unchanged_after_run = ($changed.Count -eq 0 -and $checked -gt 0) }
if (-not $postCheck.inputs_unchanged_after_run) { $errors += "post-run hash check failed: $($changed -join '; ')" }
Write-Output "Post-run hash check: $checked files, changed: $($changed.Count)"

$status = $(if ($errors.Count -eq 0 -and $shutdown.Succeeded -and $rows.Count -gt 0) { "complete" } else { "FAILED" })
# -InputObject keeps empty and single-element lists as JSON arrays (piping would drop the array or write nothing).
ConvertTo-Json -InputObject @($rows) -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory "bom-rows.json") -Encoding UTF8
$csv = foreach ($r in $rows) { $d0 = $(if ($r.component_definitions.Count) { $r.component_definitions[0] } else { $null }); [pscustomobject]@{ document = $r.document; view = $r.view; level = $r.level; parent_item = $r.parent_item; item_number = $r.item_number; item_quantity = $r.item_quantity; total_quantity = $r.total_quantity; bom_structure = $r.bom_structure.name; merged = $r.merged; promoted = $r.promoted; rolled_up = $r.rolled_up; is_virtual = $r.is_virtual; definition_kind = $(if ($d0) { $d0.kind }); component_document = $(if ($d0) { $d0.document }); part_number = $(if ($d0) { $d0.properties.part_number }); description = $(if ($d0) { $d0.properties.description }); vendor = $(if ($d0) { $d0.properties.vendor }); stock_number = $(if ($d0) { $d0.properties.stock_number }); quantity_base_units = $(if ($d0 -and $d0.quantity.available) { $d0.quantity.base_units }); quantity_unit_quantity = $(if ($d0 -and $d0.quantity.available) { $d0.quantity.unit_quantity }); occurrences = (($r.component_occurrences | ForEach-Object { $_.name }) -join ' | '); version_id = $(if ($r.source) { $r.source.version_id }); master_id = $(if ($r.source) { $r.source.master_id }) } }
$csv | Export-Csv -LiteralPath (Join-Path $OutputDirectory "bom-rows.csv") -NoTypeInformation -Encoding UTF8
ConvertTo-Json -InputObject @($views) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "bom-views.json") -Encoding UTF8
ConvertTo-Json -InputObject @($occFlags) -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory "occurrence-bom-flags.json") -Encoding UTF8
ConvertTo-Json -InputObject @($virtuals) -Depth 7 | Set-Content -LiteralPath (Join-Path $OutputDirectory "virtual-components.json") -Encoding UTF8
ConvertTo-Json -InputObject @($purchased) -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory "purchased-parts-bodies.json") -Encoding UTF8
[ordered]@{ schema_version = 1; generated_at = Utc; auditor = "windows/Audit-NativeBom.ps1"; status = $status; errors = $errors; read_only = "no document saved; BOM views enabled in memory only; acquired files re-hashed after the run"
    inventor = "$($session.Version) build $($session.Build)"; host = $env:COMPUTERNAME; assembly = [ordered]@{ document = $NativeAssembly; sha256 = (Sha $NativeAssembly) }
    session = [ordered]@{ pid = $session.Pid; ownership = $session.OwnershipMethod; pre_existing_inventor_pids = $session.PreExistingPids; shutdown = [ordered]@{ succeeded = $shutdown.Succeeded; exited = $shutdown.Exited; attempted = $shutdown.Attempted; observed = $shutdown.Observed; required = @($shutdown.Required); failed_required = @($shutdown.FailedRequired); notes = @($shutdown.Notes) } }
    project = $(if ($project) { [ordered]@{ file = $project.ProjectFile; entry_pre_existed = $project.EntryPreExisted; entry_added_by_run = $project.AddedEntry; entry_removed_by_run = $shutdown.ProjectEntryRemoved; previous_restored = $shutdown.PreviousProjectRestored } } else { $null })
    input_binding = [ordered]@{ opened_documents = $inputs.Count; verified = @($inputs | Where-Object verified).Count; inputs = $inputs }; post_run_integrity = $postCheck
    counts = [ordered]@{ assembly_documents = $views.Count; bom_rows = $rows.Count; occurrences = $occFlags.Count; suppressed_occurrences = @($occFlags | Where-Object suppressed).Count; reference_occurrences = @($occFlags | Where-Object reference).Count; excluded_occurrences = @($occFlags | Where-Object excluded).Count; virtual_components = $virtuals.Count; parts = $purchased.Count; parts_with_purchased_or_inseparable_structure = @($purchased | Where-Object bom_structure_purchased_or_inseparable).Count; multi_body_parts = @($purchased | Where-Object multi_body).Count; parts_with_hidden_bodies = @($purchased | Where-Object { $_.hidden_solid_bodies -gt 0 }).Count }
    files = [ordered]@{} } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "audit-receipt.json") -Encoding UTF8
# hash the other outputs into the receipt
$receipt = Get-Content -LiteralPath (Join-Path $OutputDirectory "audit-receipt.json") -Raw | ConvertFrom-Json
$fileHashes = [ordered]@{}; foreach ($f in Get-ChildItem -LiteralPath $OutputDirectory -File) { if ($f.Name -ne "audit-receipt.json") { $fileHashes[$f.Name] = [ordered]@{ sha256 = (Sha $f.FullName); bytes = $f.Length } } }
$receipt.files = $fileHashes
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDirectory "audit-receipt.json") -Encoding UTF8
Write-Output "Audit status: $status"
if ($status -ne "complete") { exit 1 }
