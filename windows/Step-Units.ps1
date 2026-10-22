<#
.SYNOPSIS
Determine the governing length unit of a STEP (AP203/AP214) file strictly, validating EVERY
GLOBAL_UNIT_ASSIGNED_CONTEXT instead of the first recognizable one.

.DESCRIPTION
    . (Join-Path $PSScriptRoot "Step-Units.ps1")
    $r = Get-StepLengthUnit $path   # @{ ok; unit ('mm'|'cm'|'m'|'in'|'ft'); method; reason; contexts }

Rules: the file must contain at least one GLOBAL_UNIT_ASSIGNED_CONTEXT; every referenced unit
entity must resolve; each context must reference exactly one LENGTH_UNIT entity whose unit is
recognized (SI milli/centi/plain metre, CONVERSION_BASED_UNIT 'inch'/'foot'); and all contexts
must agree. Anything else returns ok=false with a reason. Inventor files commonly declare
additional cm/mm/inch units for other purposes; only the LENGTH_UNIT referenced by the
geometric context governs the geometry. Regular expressions are single-quoted so that "\$"
is a literal dollar sign (SI_UNIT($,.METRE.)).
#>
function Get-StepLengthUnitClass([string]$definition) {
    if ($definition -match 'SI_UNIT\s*\(\s*\.CENTI\.\s*,\s*\.METRE\.') { return "cm" }
    if ($definition -match 'SI_UNIT\s*\(\s*\.MILLI\.\s*,\s*\.METRE\.') { return "mm" }
    if ($definition -match 'SI_UNIT\s*\(\s*\$\s*,\s*\.METRE\.') { return "m" }
    if ($definition -match "(?i)CONVERSION_BASED_UNIT\s*\(\s*'inch'") { return "in" }
    if ($definition -match "(?i)CONVERSION_BASED_UNIT\s*\(\s*'foot'") { return "ft" }
    return $null
}
function Get-StepLengthUnitFromText([string]$txt) {
    $fail = { param($reason, $contexts) [ordered]@{ ok = $false; unit = $null; method = "strict GLOBAL_UNIT_ASSIGNED_CONTEXT validation"; reason = $reason; contexts = @($contexts) } }
    $ctxMatches = [regex]::Matches($txt, 'GLOBAL_UNIT_ASSIGNED_CONTEXT\s*\(\s*\(([^)]*)\)')
    if ($ctxMatches.Count -eq 0) { return (& $fail "no GLOBAL_UNIT_ASSIGNED_CONTEXT in file" @()) }
    $contexts = @()
    $n = 0
    foreach ($cm in $ctxMatches) {
        $n++
        $ids = @([regex]::Matches($cm.Groups[1].Value, '#(\d+)') | ForEach-Object { $_.Groups[1].Value })
        if ($ids.Count -eq 0) { return (& $fail "context $n references no unit entities" $contexts) }
        $lengthUnits = @(); $unresolved = @()
        foreach ($id in $ids) {
            $e = [regex]::Match($txt, '(?s)(?m)^#' + $id + '\s*=\s*(.*?);')
            if (-not $e.Success) { $unresolved += "#$id"; continue }
            $def = ($e.Groups[1].Value -replace '\s+', ' ').Trim()
            if ($def -match 'LENGTH_UNIT\s*\(\s*\)') { $lengthUnits += [ordered]@{ entity = "#$id"; unit = (Get-StepLengthUnitClass $def); definition = $def } }
        }
        if ($unresolved.Count -gt 0) { return (& $fail "context $n references unresolved entities: $($unresolved -join ', ')" $contexts) }
        if ($lengthUnits.Count -ne 1) { return (& $fail "context $n has $($lengthUnits.Count) LENGTH_UNIT entities (expected exactly 1)" $contexts) }
        if (-not $lengthUnits[0].unit) { return (& $fail "context $n has an unrecognized length unit: $($lengthUnits[0].definition)" $contexts) }
        $contexts += [ordered]@{ context = $n; entity = $lengthUnits[0].entity; unit = $lengthUnits[0].unit; definition = $lengthUnits[0].definition }
    }
    $units = @($contexts | ForEach-Object { $_.unit } | Sort-Object -Unique)
    if ($units.Count -ne 1) { return (& $fail "contexts disagree on the length unit: $($units -join ', ')" $contexts) }
    [ordered]@{ ok = $true; unit = $units[0]; method = "strict GLOBAL_UNIT_ASSIGNED_CONTEXT validation: all $($contexts.Count) context(s) agree"; reason = $null; contexts = $contexts }
}
function Get-StepLengthUnit([string]$path) {
    try { return (Get-StepLengthUnitFromText ([IO.File]::ReadAllText($path))) }
    catch { return [ordered]@{ ok = $false; unit = $null; method = "strict GLOBAL_UNIT_ASSIGNED_CONTEXT validation"; reason = "read/parse error: $($_.Exception.Message)"; contexts = @() } }
}
