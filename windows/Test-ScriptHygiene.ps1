<#
.SYNOPSIS
Static checks for the PowerShell scripts in this folder (AST based, offline):
  1. parse errors;
  2. a variable assigned or used as a loop variable whose name equals a script PARAMETER name
     case-insensitively but with different casing (PowerShell variables are case-insensitive, so
     `$inventory = ...` silently overwrites `[string]$Inventory` and coerces it to a string);
  3. functions whose name is a built-in alias or cmdlet (e.g. `measure`), which the alias shadows.
Run: & .\windows\Test-ScriptHygiene.ps1
#>
$ErrorActionPreference = "Stop"
$failures = @(); $checked = 0
$builtinNames = @{}
foreach ($a in (Get-Alias)) { $builtinNames[$a.Name.ToLowerInvariant()] = "alias for $($a.Definition)" }
foreach ($c in (Get-Command -CommandType Cmdlet)) { $builtinNames[$c.Name.ToLowerInvariant()] = "cmdlet" }
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1) {
    $checked++
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { $failures += "$($file.Name): parse error: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"; continue }
    $paramNames = @()
    if ($ast.ParamBlock) { $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    $assigned = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left } | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -or $_ -is [System.Management.Automation.Language.ConvertExpressionAst] } | ForEach-Object { if ($_ -is [System.Management.Automation.Language.ConvertExpressionAst]) { $_.Child } else { $_ } } | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] })
    $loopVars = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable })
    foreach ($v in @($assigned) + @($loopVars)) {
        $name = $v.VariablePath.UserPath
        foreach ($p in $paramNames) { if ($name -ine $p) { continue }; if ($name -cne $p) { $failures += "$($file.Name):$($v.Extent.StartLineNumber): variable `$$name clashes with parameter `$$p (case-insensitive) and would overwrite it" } }
    }
    foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $n = $fn.Name.ToLowerInvariant()
        if ($builtinNames.ContainsKey($n)) { $failures += "$($file.Name):$($fn.Extent.StartLineNumber): function '$($fn.Name)' is shadowed by a built-in ($($builtinNames[$n]))" }
    }
}
if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL $_" }; Write-Output "$checked scripts checked, $($failures.Count) hygiene failure(s)"; exit 1 }
Write-Output "$checked scripts checked, no parse errors, no parameter-name clashes, no shadowed function names"
