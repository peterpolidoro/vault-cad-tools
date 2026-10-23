<#
.SYNOPSIS
Static checks for the PowerShell scripts in this folder (AST based, offline):
  1. parse errors;
  2. a variable assigned or used as a loop variable whose name equals a script PARAMETER name
     case-insensitively but with different casing (PowerShell variables are case-insensitive, so
     `$inventory = ...` silently overwrites `[string]$Inventory` and coerces it to a string);
  3. functions whose name is a built-in alias or cmdlet (e.g. `measure`), which the alias shadows;
  4. one variable spelled with different casing in the same script (`$R` matrix and `for ($r ...)` counter).
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
    # 4. the same variable name spelled with different casing anywhere in one script (`$R` and `$r` are ONE variable):
    #    a loop counter silently overwrites the other value.
    #    Scope-aware: a name inside a function body is compared only with names in that same function; names outside
    #    any function form the script scope (a function parameter `$M` and a top-level `$m` are different variables).
    $spellings = @{}
    foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($name -match '^(_|this|args|input|null|true|false|PSScriptRoot|PSItem|LASTEXITCODE|env:.*|script:.*|global:.*|using:.*)$') { continue }
        $scope = "<script>"; $p = $v.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $p.Name; break }; $p = $p.Parent }
        $bare = ($name -replace '^(script|global|local|private):', '')
        $key = "$scope|" + $bare.ToLowerInvariant()
        if (-not $spellings.ContainsKey($key)) { $spellings[$key] = @{} }
        $spellings[$key][$bare] = $v.Extent.StartLineNumber
    }
    foreach ($key in $spellings.Keys) { if ($spellings[$key].Count -gt 1) { $failures += "$($file.Name): in scope $($key.Split('|')[0]) the variable is spelled $(($spellings[$key].Keys | Sort-Object | ForEach-Object { '$' + $_ }) -join ' and ') (lines $(($spellings[$key].Values | Sort-Object -Unique) -join ', ')); PowerShell treats these as ONE variable" } }
}
if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL $_" }; Write-Output "$checked scripts checked, $($failures.Count) hygiene failure(s)"; exit 1 }
Write-Output "$checked scripts checked, no parse errors, no parameter-name clashes, no shadowed function names"
