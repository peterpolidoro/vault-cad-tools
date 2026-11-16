<#
.SYNOPSIS
Static checks for the PowerShell scripts in this folder (AST based, offline):
  1. parse errors;
  2. a variable assigned or used as a loop variable whose name equals a script PARAMETER name
     case-insensitively but with different casing (PowerShell variables are case-insensitive, so
     `$inventory = ...` silently overwrites `[string]$Inventory` and coerces it to a string);
  3. functions whose name is a built-in alias or cmdlet (e.g. `measure`), which the alias shadows;
  4. one variable spelled with different casing in the same scope (`$R` matrix and `for ($r ...)` counter);
  5. a Vault session's id or token inside a text (a text is what reaches a log, a receipt or the screen); the
     one text that may hold the token is the Authorization header;
  6. a web request that is not a GET, other than the sign-in (POST sessions/win-auth): the scripts read from
     Vault's REST API and never write through it.
Every run first proves the checks on built-in snippets (a clash that must be found, names that must not be
flagged); a checker that cannot find its own target fails the run instead of reporting clean scripts.
Run: & .\windows\Test-ScriptHygiene.ps1
#>
$ErrorActionPreference = "Stop"
$builtinNames = @{}
foreach ($a in (Get-Alias)) { $builtinNames[$a.Name.ToLowerInvariant()] = "alias for $($a.Definition)" }
foreach ($c in (Get-Command -CommandType Cmdlet)) { $builtinNames[$c.Name.ToLowerInvariant()] = "cmdlet" }

function Get-HygieneFailures {
    # Checks 2 to 4 on one parsed script; returns the failure texts (without the file name).
    param($Ast, $Builtins)
    $found = @()
    $paramNames = @()
    if ($Ast.ParamBlock) { $paramNames = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    $assigned = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | ForEach-Object { $_.Left } | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -or $_ -is [System.Management.Automation.Language.ConvertExpressionAst] } | ForEach-Object { if ($_ -is [System.Management.Automation.Language.ConvertExpressionAst]) { $_.Child } else { $_ } } | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] })
    $loopVars = @($Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable })
    foreach ($v in @($assigned) + @($loopVars)) {
        $name = $v.VariablePath.UserPath
        foreach ($p in $paramNames) { if ($name -ine $p) { continue }; if ($name -cne $p) { $found += "line $($v.Extent.StartLineNumber): variable `$$name clashes with parameter `$$p (case-insensitive) and would overwrite it" } }
    }
    foreach ($fn in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $n = $fn.Name.ToLowerInvariant()
        if ($Builtins.ContainsKey($n)) { $found += "line $($fn.Extent.StartLineNumber): function '$($fn.Name)' is shadowed by a built-in ($($Builtins[$n]))" }
    }
    # 4. the same variable name spelled with different casing in one scope (`$R` and `$r` are ONE variable): a loop
    #    counter silently overwrites the other value. Scope-aware: a name inside a function body is compared only
    #    with names in that same function; names outside any function form the script scope.
    #    The tables are ORDINAL (case-sensitive) dictionaries read through methods: a PowerShell hashtable literal
    #    is case-insensitive, which merged the spellings this check exists to tell apart, and its dot access
    #    returns the value of a key named "count" instead of the number of entries.
    $spellings = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.Dictionary[string,int]]' ([StringComparer]::Ordinal)
    foreach ($v in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $name = $v.VariablePath.UserPath
        if ($name -match '^(_|this|args|input|null|true|false|PSScriptRoot|PSCommandPath|PSItem|PID|Matches|LASTEXITCODE|env:.*|script:.*|global:.*|using:.*|local:.*|private:.*)$') { continue }
        $scope = "<script>"; $p = $v.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $scope = $p.Name; break }; $p = $p.Parent }
        $key = "$scope|" + $name.ToLowerInvariant()
        if (-not $spellings.ContainsKey($key)) { $spellings.Add($key, (New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal))) }
        $inner = $spellings.get_Item($key)
        if (-not $inner.ContainsKey($name)) { $inner.Add($name, $v.Extent.StartLineNumber) }
    }
    foreach ($key in @($spellings.get_Keys())) {
        $inner = $spellings.get_Item($key)
        if ($inner.get_Count() -gt 1) {
            $forms = @($inner.get_Keys() | Sort-Object -CaseSensitive)
            $found += "in scope $($key.Split('|')[0]) one variable is spelled $(($forms | ForEach-Object { '$' + $_ + ' (first at line ' + $inner.get_Item($_) + ')' }) -join ' and '); PowerShell treats these as ONE variable"
        }
    }
    # 5. a session's id or token inside a text. The Authorization header ("Bearer ...") is the one text that holds
    #    the token; a session's id belongs in none.
    foreach ($text in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($text.Value -cmatch '^Bearer ') { continue }
        $secrets = @()
        foreach ($nested in @($text.NestedExpressions)) {
            foreach ($node in @($nested.FindAll({ $true }, $true))) {
                if ($node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    if ($node.Member.Value -ieq "accessToken") { $secrets += "an access token" }
                    elseif ($node.Member.Value -ieq "id" -and $node.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -ieq "session") { $secrets += "a session's id" }
                } elseif ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -ieq "env:VAULT_CAD_TOKEN") { $secrets += "the session token" }
            }
        }
        foreach ($secret in @($secrets | Sort-Object -Unique)) { $found += "line $($text.Extent.StartLineNumber): a text holds $secret; no log, receipt or message may" }
    }
    # 6. a web request that is not a GET. A request without -Method is a GET; one whose parameters are splatted, or
    #    whose method is not the word Get, is refused unless it is the sign-in.
    foreach ($command in $Ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if (@("Invoke-RestMethod", "Invoke-WebRequest", "irm", "iwr", "curl", "wget") -notcontains $command.GetCommandName()) { continue }
        $elements = @($command.CommandElements); $method = $null; $address = ""; $splatted = $false
        for ($i = 1; $i -lt $elements.Count; $i++) {
            if ($elements[$i] -is [System.Management.Automation.Language.VariableExpressionAst] -and $elements[$i].Splatted) { $splatted = $true }
            if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $given = $elements[$i].ParameterName
            $value = $(if ($null -ne $elements[$i].Argument) { $elements[$i].Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null })
            if ($null -eq $value) { continue }
            if ($given.Length -ge 2 -and "Method".StartsWith($given, [StringComparison]::OrdinalIgnoreCase)) { $method = $value.Extent.Text.Trim([char[]]@([char]39, [char]34)) }
            if ($given -ieq "Uri") { $address = $value.Extent.Text }
        }
        if ($splatted) { $found += "line $($command.Extent.StartLineNumber): a web request with splatted parameters; its method cannot be read here" }
        elseif ($null -ne $method -and $method -ine "Get" -and $address -notmatch 'sessions/win-auth') { $found += "line $($command.Extent.StartLineNumber): a web request with -Method $method that is not the sign-in; these scripts read from Vault and never write through REST" }
    }
    return $found   # bare: callers wrap with @(...); a comma-wrapped empty array would arrive as one empty item
}

function Test-Snippet([string]$Text) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { return "parse error: $($errs[0].Message)" }
    return @(Get-HygieneFailures $ast $builtinNames)
}

# ---- the checks prove themselves first ----
$selfFailures = @()
function Expect([string]$What, [string]$Text, [string]$Pattern, [int]$Count) {
    $got = @(Test-Snippet $Text)
    $matching = @($got | Where-Object { $_ -match $Pattern })
    if ($matching.Count -ne $Count -or ($Count -eq 0 -and $got.Count -ne 0)) { $script:selfFailures += "self-test '$What': expected $Count finding(s) matching /$Pattern/, got: $(if ($got.Count) { $got -join ' | ' } else { '(none)' })" }
}
Expect "4 finds a matrix and a loop counter that differ only by case" '$R = @(1, 2); for ($r = 0; $r -lt 2; $r++) { $R[$r] }' 'spelled \$R .* and \$r ' 1
Expect "4 does not flag variables named count, keys or values" 'function F { $count = 3; $keys = @(1); $values = @(2); for ($i = 1; $i -le $count; $i++) { $keys + $values } }' '.' 0
Expect "4 keeps function scopes apart" 'function A($M) { $M } ; $m = 1; function B { $m = 2; $m }' '.' 0
Expect "4 finds a clash inside one function" 'function A($Path) { $path = 1; $Path }' 'in scope A one variable is spelled \$Path .* and \$path ' 1
Expect "4 finds a clash between a parameter read and a later loop variable in script scope" 'param($Items) foreach ($items in 1..2) { $items }' 'spelled \$Items .* and \$items ' 1
Expect "2 finds an assignment that overwrites a parameter under another casing" 'param([string]$Inventory) $inventory = 1' 'clashes with parameter \$Inventory' 1
Expect "3 finds a function shadowed by an alias" 'function measure { 1 }' "function 'measure' is shadowed" 1
Expect "5 finds a session's id in a text that is written out" 'Write-Output "Session $($session.id) as $($session.userInformation.name)"' "a text holds a session's id" 1
Expect "5 finds an access token in a text" 'Write-Host "token $($session.accessToken)"' 'a text holds an access token' 1
Expect "5 finds the token of the environment in a text" 'Add-Content -LiteralPath $log -Value "token=$env:VAULT_CAD_TOKEN"' 'a text holds the session token' 1
Expect "5 lets the Authorization header and a user name pass" '$one = @{ Authorization = "Bearer $($session.accessToken)" }; $two = @{ Authorization = "Bearer $env:VAULT_CAD_TOKEN" }; Write-Output "Signed in as $($session.userInformation.name)"' '.' 0
Expect "6 finds a request that is not a GET" 'Invoke-RestMethod -Uri "$base/vaults/1/file-versions/2" -Method Put -Body $content' 'a web request with -Method Put that is not the sign-in' 1
Expect "6 finds a request whose parameters are splatted" 'Invoke-RestMethod @request' 'a web request with splatted parameters' 1
Expect "6 lets the sign-in, a GET and a download pass" 'Invoke-RestMethod -Uri "$base/sessions/win-auth" -Method Post -Body $content; Invoke-RestMethod -Uri $address -Method Get; Invoke-WebRequest -Uri $address -OutFile $file' '.' 0
Expect "a clean script has no finding" 'param([string]$Path) $total = 0; foreach ($item in 1..3) { $total += $item }; function Get-Thing($Value) { $Value }' '.' 0
Expect "a parse error is reported" 'function {' 'parse error' 1
if ($selfFailures.Count) { $selfFailures | ForEach-Object { Write-Output "FAIL $_" }; Write-Output "the hygiene checks failed their own self-test ($($selfFailures.Count)); no script was judged"; exit 1 }

$failures = @(); $checked = 0
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1) {
    $checked++
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { $failures += "$($file.Name): parse error: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"; continue }
    foreach ($text in @(Get-HygieneFailures $ast $builtinNames)) { $failures += "$($file.Name): $text" }
}
if ($failures.Count) { $failures | ForEach-Object { Write-Output "FAIL $_" }; Write-Output "$checked scripts checked, $($failures.Count) hygiene failure(s)"; exit 1 }
Write-Output "$checked scripts checked (self-test of the checks: 16 cases passed), no parse errors, no parameter-name clashes, no shadowed function names, no variable spelled with two casings in one scope, no session id or token in a text, no web request other than a GET and the sign-in"
