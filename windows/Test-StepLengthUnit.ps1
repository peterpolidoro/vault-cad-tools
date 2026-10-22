<#
.SYNOPSIS
Offline fixtures for Step-Units.ps1: mm, inch, cm, SI metre, unknown, missing context, mixed
contexts, unresolved entity, two LENGTH_UNITs in one context. Run: & .\windows\Test-StepLengthUnit.ps1
#>
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Step-Units.ps1")
function Ctx($unitEntity) { @"
ISO-10303-21;
HEADER; ENDSEC;
DATA;
#10=( LENGTH_UNIT() NAMED_UNIT(*) $unitEntity );
#11=( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT(`$,.RADIAN.) );
#12=( NAMED_UNIT(*) SI_UNIT(`$,.STERADIAN.) SOLID_ANGLE_UNIT() );
#20=( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#30)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#10,#11,#12)) REPRESENTATION_CONTEXT('','') );
#30=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-7),#10,'','');
ENDSEC;
END-ISO-10303-21;
"@ }
$inch = "ISO-10303-21;`nDATA;`n#9=DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.);`n#10=( CONVERSION_BASED_UNIT('inch',#13) LENGTH_UNIT() NAMED_UNIT(#9) );`n#13=LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),#14);`n#14=( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );`n#11=( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT(`$,.RADIAN.) );`n#20=( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#10,#11)) REPRESENTATION_CONTEXT('','') );`nENDSEC;`nEND-ISO-10303-21;"
$mixed = (Ctx "SI_UNIT(.MILLI.,.METRE.)") + "`n#40=( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.CENTI.,.METRE.) );`n#50=( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#40,#11,#12)) REPRESENTATION_CONTEXT('','') );"
$unresolved = (Ctx "SI_UNIT(.MILLI.,.METRE.)") + "`n#50=( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#99,#11,#12)) REPRESENTATION_CONTEXT('','') );"
$twoLengths = (Ctx "SI_UNIT(.MILLI.,.METRE.)") -replace '#11=\( NAMED_UNIT\(\*\) PLANE_ANGLE_UNIT\(\) SI_UNIT\(\$,\.RADIAN\.\) \);', '#11=( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.CENTI.,.METRE.) );'
$cases = @(
    @{ name = "mm";          text = (Ctx "SI_UNIT(.MILLI.,.METRE.)"); ok = $true;  unit = "mm" },
    @{ name = "cm";          text = (Ctx "SI_UNIT(.CENTI.,.METRE.)"); ok = $true;  unit = "cm" },
    @{ name = "metre";       text = (Ctx "SI_UNIT(`$,.METRE.)");      ok = $true;  unit = "m" },
    @{ name = "inch";        text = $inch;                            ok = $true;  unit = "in" },
    @{ name = "unknown";     text = (Ctx "SI_UNIT(.KILO.,.METRE.)");  ok = $false; reason = "unrecognized" },
    @{ name = "missing";     text = "ISO-10303-21;`nDATA;`n#1=CARTESIAN_POINT('',(0.,0.,0.));`nENDSEC;`nEND-ISO-10303-21;"; ok = $false; reason = "no GLOBAL_UNIT_ASSIGNED_CONTEXT" },
    @{ name = "mixed";       text = $mixed;                           ok = $false; reason = "disagree" },
    @{ name = "unresolved";  text = $unresolved;                      ok = $false; reason = "unresolved" },
    @{ name = "two_lengths"; text = $twoLengths;                      ok = $false; reason = "expected exactly 1" },
    @{ name = "metre_regex_literal_dollar_not_backslash"; text = ((Ctx "SI_UNIT(`$,.METRE.)") -replace 'SI_UNIT\(\$,\.METRE\.\)', 'SI_UNIT(\$,.METRE.)'); ok = $false; reason = "unrecognized" }
)
$passed = 0; $failed = 0
foreach ($c in $cases) {
    $r = Get-StepLengthUnitFromText $c.text
    $good = ($r.ok -eq $c.ok) -and ((-not $c.ok) -or ($r.unit -eq $c.unit)) -and ($c.ok -or ($r.reason -match [regex]::Escape($c.reason)))
    if ($good) { $passed++; Write-Output "PASS $($c.name): ok=$($r.ok) unit=$($r.unit) $($r.reason)" } else { $failed++; Write-Output "FAIL $($c.name): expected ok=$($c.ok) unit=$($c.unit) reason~'$($c.reason)' got ok=$($r.ok) unit=$($r.unit) reason='$($r.reason)'" }
}
Write-Output "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
