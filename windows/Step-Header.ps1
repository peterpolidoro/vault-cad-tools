<#
.SYNOPSIS
Shared helpers that read and rewrite the header of a STEP file (ISO 10303-21) as bytes, without a CAD kernel.

.DESCRIPTION
Dot-source from a script in the same folder:

    . (Join-Path $PSScriptRoot "Step-Header.ps1")
    $info = Get-StepFileInfo -Path FILE
    $done = Set-StepFileHeader -Path IN -OutPath OUT            # the normalised header of the layout specification

Get-StepFileInfo returns the three text identities and the header fields: sha256 of the file, data_sha256 (the
bytes from the DATA keyword to the end of the file), bytes, data_offset, the FILE_NAME fields (name, time_stamp,
author, organization, preprocessor_version, originating_system, authorisation), FILE_DESCRIPTION, FILE_SCHEMA and
the protocol it names, and the header text itself.

Set-StepFileHeader replaces the FILE_NAME statement and nothing else. With its defaults it writes the normalised
header: name "part.step", time stamp 1970-01-01T00:00:00, empty author, organization and authorisation; the
preprocessor and originating-system strings are kept. It refuses to overwrite, refuses non-ASCII header strings,
and proves on every call that the data-section hash did not change.

This is a port of mechanical-cad/mechanical_cad/stepfile.py (sections, data_sha256, header, normalise_header):
the same statement scanner (semicolons inside strings and comments do not end a statement; '' is an escaped
quote), the same definition of the data section, and the same replacement text, so both sides produce identical
bytes from the same input. Bytes are handled as ISO 8859-1 text so that a character index is a byte offset.
Offline tests: Test-StepHeader.ps1.
#>
$StepLatin1 = [Text.Encoding]::GetEncoding(28591)
$StepNormalisedTimeStamp = "1970-01-01T00:00:00"
$StepNormalisedName = "part.step"
$StepProtocols = @(
    @("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING", "AP242"),
    @("AP203_CONFIGURATION_CONTROLLED_3D_DESIGN", "AP203E2"),
    @("AUTOMOTIVE_DESIGN", "AP214"),
    @("CONFIG_CONTROL_DESIGN", "AP203")
)
$StepSpaceChars = " `t`n`r" + [char]11 + [char]12

function Test-StepSpace($Char) { $StepSpaceChars.IndexOf([char]$Char) -ge 0 }

function Skip-StepToken {
    # If a string or a comment starts at Index, return the index just past it; otherwise Index.
    param([string]$Text, [int]$Index)
    if ($Index -ge $Text.Length) { return $Index }
    $first = $Text[$Index]
    if ($first -eq [char]39) {
        $from = $Index + 1
        while ($true) {
            $quote = $Text.IndexOf([char]39, $from)
            if ($quote -lt 0) { throw "STEP: unterminated string" }
            if (($quote + 1) -lt $Text.Length -and $Text[$quote + 1] -eq [char]39) { $from = $quote + 2; continue }
            return $quote + 1
        }
    }
    if ($first -eq [char]47 -and ($Index + 1) -lt $Text.Length -and $Text[$Index + 1] -eq [char]42) {
        $close = $Text.IndexOf("*/", $Index + 2, [StringComparison]::Ordinal)
        if ($close -lt 0) { throw "STEP: unterminated comment" }
        return $close + 2
    }
    return $Index
}

function Get-StepSections {
    <# Offsets of the header and of the data section: HeaderStart (just past HEADER;), HeaderEnd (start of the
       header's ENDSEC), DataStart (start of the DATA keyword), Statements (Start/End of every header statement).
       Scans only up to the DATA statement, never the data section. #>
    param([string]$Text)
    $index = 0; $begin = -1; $head = -1; $headerEnd = -1
    $statements = New-Object System.Collections.ArrayList
    $length = $Text.Length
    while ($index -lt $length) {
        $past = Skip-StepToken $Text $index
        if ($past -ne $index) {
            if ($begin -lt 0 -and $Text[$index] -eq [char]39) { $begin = $index }
            $index = $past
            continue
        }
        $current = $Text[$index]
        if ($current -eq [char]59) {
            if ($begin -ge 0) {
                $word = $Text.Substring($begin, $index - $begin).Trim().ToUpperInvariant()
                if ($head -lt 0) { if ($word -eq "HEADER") { $head = $index + 1 } }
                elseif ($headerEnd -lt 0) { if ($word -eq "ENDSEC") { $headerEnd = $begin } else { [void]$statements.Add(@{ Start = $begin; End = $index + 1 }) } }
                elseif ($word -eq "DATA") { return @{ HeaderStart = $head; HeaderEnd = $headerEnd; DataStart = $begin; Statements = $statements } }
                else { throw "STEP: no DATA section after the header" }
            }
            $begin = -1
        } elseif ($begin -lt 0 -and -not (Test-StepSpace $current)) { $begin = $index }
        $index++
    }
    if ($head -lt 0) { throw "STEP: no HEADER section" }
    if ($headerEnd -lt 0) { throw "STEP: the header is not closed by ENDSEC" }
    throw "STEP: no DATA section after the header"
}

function ConvertFrom-StepString([string]$Raw) { ($Raw.Substring(1, $Raw.Length - 2) -replace "[`r`n]", "").Replace("''", "'") }
function ConvertTo-StepString([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

function Read-StepParams {
    # Text[Index] is "("; returns Values (strings, bare tokens, nested lists) and Next (the index past ")").
    param([string]$Text, [int]$Index)
    $index2 = $Index + 1; $values = New-Object System.Collections.ArrayList; $token = ""
    while ($index2 -lt $Text.Length) {
        $past = Skip-StepToken $Text $index2
        if ($past -ne $index2) {
            if ($Text[$index2] -eq [char]39) { [void]$values.Add((ConvertFrom-StepString $Text.Substring($index2, $past - $index2))) }
            $index2 = $past
            continue
        }
        $current = $Text[$index2]
        if ($current -eq [char]40) { $nested = Read-StepParams $Text $index2; [void]$values.Add($nested.Values); $index2 = $nested.Next; continue }
        if ($current -eq [char]41) { if ($token.Trim()) { [void]$values.Add($token.Trim()) }; return @{ Values = $values; Next = $index2 + 1 } }
        if ($current -eq [char]44) { if ($token.Trim()) { [void]$values.Add($token.Trim()) }; $token = "" }
        elseif (-not (Test-StepSpace $current)) { $token += $current }
        $index2++
    }
    throw "STEP: unterminated parameter list"
}

function Get-StepHeaderEntities {
    # NAME -> Params, Start, End for every statement of the header section.
    param([string]$Text, $Sections)
    $entities = @{}
    foreach ($statement in $Sections.Statements) {
        $body = $Text.Substring($statement.Start, $statement.End - $statement.Start)
        $match = [regex]::Match($body, '^\s*([A-Za-z_][A-Za-z0-9_]*)')
        if (-not $match.Success) { continue }
        $open = $body.IndexOf([char]40)
        if ($open -lt 0) { continue }
        $parsed = Read-StepParams $Text ($statement.Start + $open)
        $entities[$match.Groups[1].Value.ToUpperInvariant()] = @{ Params = $parsed.Values; Start = $statement.Start; End = $statement.End }
    }
    return $entities
}

function Get-StepListValue($Value) {
    # A FILE_NAME list field as an array of strings (a bare string becomes a one-element array).
    if ($null -eq $Value) { return ,@() }
    if ($Value -is [System.Collections.ArrayList]) { return ,@($Value | ForEach-Object { [string]$_ }) }
    return ,@([string]$Value)
}

function ConvertTo-StepHex([byte[]]$Hash) { ([BitConverter]::ToString($Hash) -replace '-', '').ToLowerInvariant() }

function Get-StepHeaderFields {
    # The header fields of an already parsed file; missing fields are $null.
    param($Entities)
    $fields = [ordered]@{ name = $null; time_stamp = $null; author = $null; organization = $null; preprocessor_version = $null; originating_system = $null; authorisation = $null
        description = $null; implementation_level = $null; schema = $null; protocol = $null }
    if ($Entities.ContainsKey("FILE_NAME")) {
        $fileName = @($Entities["FILE_NAME"].Params) + @($null, $null, $null, $null, $null, $null, $null)
        $fields.name = $fileName[0]; $fields.time_stamp = $fileName[1]
        $fields.author = Get-StepListValue $fileName[2]; $fields.organization = Get-StepListValue $fileName[3]
        $fields.preprocessor_version = $fileName[4]; $fields.originating_system = $fileName[5]; $fields.authorisation = $fileName[6]
    }
    if ($Entities.ContainsKey("FILE_DESCRIPTION")) {
        $description = @($Entities["FILE_DESCRIPTION"].Params) + @($null, $null)
        $fields.description = Get-StepListValue $description[0]; $fields.implementation_level = $description[1]
    }
    if ($Entities.ContainsKey("FILE_SCHEMA")) {
        $schemaList = Get-StepListValue (@($Entities["FILE_SCHEMA"].Params) + @($null))[0]
        if ($schemaList.Count -gt 0) {
            $fields.schema = $schemaList[0]
            foreach ($pair in $StepProtocols) { if ($fields.schema.ToUpperInvariant().Contains($pair[0])) { $fields.protocol = $pair[1]; break } }
        }
    }
    return $fields
}

function Get-StepFileInfo {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "STEP file not found: $Path" }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    $text = $StepLatin1.GetString($bytes)
    $sections = Get-StepSections $text
    $entities = Get-StepHeaderEntities $text $sections
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $whole = ConvertTo-StepHex $hasher.ComputeHash($bytes)
        $data = ConvertTo-StepHex $hasher.ComputeHash($bytes, $sections.DataStart, $bytes.Length - $sections.DataStart)
    } finally { $hasher.Dispose() }
    $headerText = $text.Substring(0, $sections.DataStart)
    $statementText = @{}
    foreach ($key in @("FILE_DESCRIPTION", "FILE_NAME", "FILE_SCHEMA")) { if ($entities.ContainsKey($key)) { $statementText[$key] = $text.Substring($entities[$key].Start, $entities[$key].End - $entities[$key].Start) } }
    [pscustomobject]@{ path = $Path; bytes = $bytes.Length; sha256 = $whole; data_sha256 = $data; data_offset = $sections.DataStart
        header = (Get-StepHeaderFields $entities)
        header_sha256 = $(if ($sections.DataStart -gt 0) { $h2 = [Security.Cryptography.SHA256]::Create(); try { ConvertTo-StepHex $h2.ComputeHash($bytes, 0, $sections.DataStart) } finally { $h2.Dispose() } } else { $null })
        header_text = $headerText; header_lines = @($headerText -split "`r?`n")
        file_name_statement = $statementText["FILE_NAME"]; file_schema_statement = $statementText["FILE_SCHEMA"]; file_description_statement = $statementText["FILE_DESCRIPTION"]
        line_ending = $(if ($headerText.Contains("`r`n")) { "CRLF" } elseif ($headerText.Contains("`n")) { "LF" } else { "none" }) }
}

function Set-StepFileHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OutPath,
        [string]$Name = $StepNormalisedName,
        [string]$TimeStamp = $StepNormalisedTimeStamp,
        [string]$Author = "",
        [string]$Organization = "",
        [string]$Authorisation = ""
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "STEP file not found: $Path" }
    if (Test-Path -LiteralPath $OutPath) { throw "Refusing to overwrite: $OutPath" }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    $text = $StepLatin1.GetString($bytes)
    $sections = Get-StepSections $text
    $entities = Get-StepHeaderEntities $text $sections
    if (-not $entities.ContainsKey("FILE_NAME")) { throw "STEP: the header has no FILE_NAME" }
    $fields = Get-StepHeaderFields $entities
    $kept = @([string]$fields.preprocessor_version, [string]$fields.originating_system)
    foreach ($value in @($Name, $TimeStamp, $Author, $Organization, $Authorisation) + $kept) { if ($value -match '[^\x20-\x7E]') { throw "STEP: header string '$value' is not printable ASCII; normalise this file on Linux" } }
    $statement = "FILE_NAME(" + (@((ConvertTo-StepString $Name), (ConvertTo-StepString $TimeStamp), ("(" + (ConvertTo-StepString $Author) + ")"), ("(" + (ConvertTo-StepString $Organization) + ")"),
        (ConvertTo-StepString $kept[0]), (ConvertTo-StepString $kept[1]), (ConvertTo-StepString $Authorisation)) -join ",") + ");"
    $start = [int]$entities["FILE_NAME"].Start; $end = [int]$entities["FILE_NAME"].End
    $replacement = $StepLatin1.GetBytes($statement)
    $result = New-Object byte[] ($start + $replacement.Length + ($bytes.Length - $end))
    [Array]::Copy($bytes, 0, $result, 0, $start)
    [Array]::Copy($replacement, 0, $result, $start, $replacement.Length)
    [Array]::Copy($bytes, $end, $result, $start + $replacement.Length, $bytes.Length - $end)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $before = ConvertTo-StepHex $hasher.ComputeHash($bytes, $sections.DataStart, $bytes.Length - $sections.DataStart)
        $shift = $replacement.Length - ($end - $start)
        $after = ConvertTo-StepHex $hasher.ComputeHash($result, $sections.DataStart + $shift, $result.Length - ($sections.DataStart + $shift))
        $inputHash = ConvertTo-StepHex $hasher.ComputeHash($bytes); $outputHash = ConvertTo-StepHex $hasher.ComputeHash($result)
    } finally { $hasher.Dispose() }
    if ($before -ne $after) { throw "STEP: rewriting the header changed the data section ($before -> $after); nothing written" }
    $resultSections = Get-StepSections ($StepLatin1.GetString($result, 0, [Math]::Min($result.Length, $sections.DataStart + $shift + 16)))
    if ($resultSections.DataStart -ne ($sections.DataStart + $shift)) { throw "STEP: the rewritten header does not parse back to the same data offset; nothing written" }
    [IO.File]::WriteAllBytes($OutPath, $result)
    [pscustomobject]@{ input = $Path; output = $OutPath; input_sha256 = $inputHash; output_sha256 = $outputHash; data_sha256 = $after; data_sha256_unchanged = $true
        input_bytes = $bytes.Length; output_bytes = $result.Length; replaced_statement = $text.Substring($start, $end - $start); new_statement = $statement
        bytes_before_statement_unchanged = $true; bytes_after_statement_unchanged = $true; changed = ($inputHash -ne $outputHash) }
}
