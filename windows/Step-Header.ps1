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

Data-section helpers (text level, no kernel):
  Get-StepEntityCounts -Path FILE [-Type NAME,...]   how many instances of each entity type (default
                                                      MANIFOLD_SOLID_BREP, INVISIBILITY, CAMERA_MODEL_D3)
  Get-StepEntities -Path FILE                         every instance: id -> Type and Body
  Get-StepInvisibility -Path FILE                     what the file marks invisible and whether the mark has the
                                                      one form mechanical-cad's visible_only understands
  Compare-StepEntities -FirstPath A -OtherPath B      instances (matched by id) that differ or exist in one file
  Get-StepReferenceClosure, Test-StepViewBlockConfinement   is a difference between two exports confined to the
                                                      saved view (everything reachable from CAMERA_MODEL_D3)?
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

# ---------------------------------------------------------------------------------------------------------
# Data-section entities, read as text (no kernel). An entity instance is "#id = TYPE(...);" or, for a complex
# instance, "#id = (A(...) B(...));"; semicolons inside strings do not end it.
# ---------------------------------------------------------------------------------------------------------
$StepEntityPattern = "#(\d+)\s*=\s*([A-Z0-9_]*)\s*((?:[^';]+|'(?:[^']|'')*')*);"

function Get-StepDataText {
    # The data section of a file as ISO 8859-1 text, from the DATA keyword to the end of the file.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "STEP file not found: $Path" }
    $text = $StepLatin1.GetString([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path))
    $sections = Get-StepSections $text
    return $text.Substring($sections.DataStart)
}

function Get-StepEntityCounts {
    # How many instances of each named entity type the data section holds (simple instances only).
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$Type = @("MANIFOLD_SOLID_BREP", "INVISIBILITY", "CAMERA_MODEL_D3"))
    $data = Get-StepDataText -Path $Path
    $counts = [ordered]@{}
    foreach ($name in $Type) { $counts[$name] = [regex]::Matches($data, "#\d+\s*=\s*" + [regex]::Escape($name) + "\s*\(").Count }
    return $counts
}

function Get-StepEntities {
    <# Every entity instance of the data section in a dictionary keyed by its id: Id, Type ('' for a complex
       instance) and Body (the text after the type up to the closing ';', white space collapsed). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $data = Get-StepDataText -Path $Path
    $entities = New-Object 'System.Collections.Generic.Dictionary[int,object]'
    foreach ($match in [regex]::Matches($data, $StepEntityPattern)) {
        $id = [int]$match.Groups[1].Value
        if (-not $entities.ContainsKey($id)) { $entities.Add($id, [pscustomobject]@{ Id = $id; Type = $match.Groups[2].Value; Body = ($match.Groups[3].Value -replace '\s+', ' ').Trim() }) }
    }
    return $entities
}

function Get-StepInvisibility {
    <# What a file marks invisible, and whether the mark has the one form mechanical-cad understands
       (mechanical_cad/stepfile.py, visible_only): an INVISIBILITY whose members are STYLED_ITEMs (or
       OVER_RIDING_STYLED_ITEMs), each styling an item that is used, apart from its styled items, only in the
       item list of representations, and is in at least one. Anything else is listed under problems. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $result = [ordered]@{ invisibility_entities = 0; hidden_items = @(); form_understood = $true; problems = @() }
    $data = Get-StepDataText -Path $Path
    if (-not $data.Contains("INVISIBILITY")) { return $result }
    $entities = Get-StepEntities -Path $Path
    $styled = @("STYLED_ITEM", "OVER_RIDING_STYLED_ITEM")
    $hidden = @{}; $problems = @(); $count = 0
    foreach ($entity in $entities.get_Values()) {
        if ($entity.Type -ne "INVISIBILITY") { continue }
        $count++
        $inner = [regex]::Match($entity.Body, '^\(\s*\(([^()]*)\)\s*\)$')
        if (-not $inner.Success) { $problems += "#$($entity.Id) INVISIBILITY does not have one list of members"; continue }
        foreach ($reference in [regex]::Matches($inner.Groups[1].Value, '#(\d+)')) {
            $member = $null; [void]$entities.TryGetValue([int]$reference.Groups[1].Value, [ref]$member)
            if ($null -eq $member -or $styled -notcontains $member.Type) { $problems += "#$($entity.Id) INVISIBILITY hides #$($reference.Groups[1].Value), which is not a STYLED_ITEM ($(if ($member) { $member.Type } else { 'missing' }))"; continue }
            $item = [regex]::Match($member.Body, '#(\d+)\s*\)$')
            if (-not $item.Success) { $problems += "#$($member.Id) $($member.Type) does not name the item it styles"; continue }
            $hidden[[int]$item.Groups[1].Value] = [ordered]@{ invisibility = $entity.Id; styled_item = $member.Id; styled_item_type = $member.Type; representations = @() }
        }
    }
    $result.invisibility_entities = $count
    if ($hidden.Count -gt 0) {
        foreach ($entity in $entities.get_Values()) {
            if ($entity.Type -eq "INVISIBILITY" -or $styled -contains $entity.Type) { continue }
            if (-not $entity.Body.Contains("#")) { continue }
            $bare = [regex]::Replace($entity.Body, "'(?:[^']|'')*'", "''")   # a "#12" inside a string is not a reference
            $used = @([regex]::Matches($bare, '#(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $hidden.ContainsKey($_) })
            if ($used.Count -eq 0) { continue }
            $typeName = $(if ($entity.Type) { $entity.Type } else { "a complex instance" })
            $items = [regex]::Match($bare, "^\(\s*''\s*,\s*\(([^()]*)\)")
            if (-not $entity.Type.EndsWith("REPRESENTATION") -or -not $items.Success) { $problems += "#$($used[0]) is marked invisible and is used by #$($entity.Id) ($typeName); only items listed directly in a representation can be left out"; continue }
            $listed = @([regex]::Matches($items.Groups[1].Value, '#(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Where-Object { $hidden.ContainsKey($_) })
            if ($listed.Count -ne $used.Count) { $problems += "#$($entity.Id) $typeName uses an invisible item outside its list of items" }
            foreach ($itemId in ($listed | Sort-Object -Unique)) { $hidden[$itemId].representations += "#$($entity.Id) $typeName" }
        }
        foreach ($itemId in ($hidden.Keys | Sort-Object)) {
            $itemEntity = $null; [void]$entities.TryGetValue([int]$itemId, [ref]$itemEntity)
            if (@($hidden[$itemId].representations).Count -eq 0) { $problems += "#$itemId is marked invisible but is not an item of any representation" }
            $result.hidden_items += [ordered]@{ item = [int]$itemId; item_type = $(if ($itemEntity) { $itemEntity.Type } else { $null }); styled_item = $hidden[$itemId].styled_item; styled_item_type = $hidden[$itemId].styled_item_type
                invisibility = $hidden[$itemId].invisibility; representations = @($hidden[$itemId].representations) }
        }
    }
    $result.problems = $problems; $result.form_understood = ($problems.Count -eq 0)
    return $result
}

function Get-StepReferenceClosure {
    # The ids reachable from the given roots by following #n references (a "#n" inside a string is not one).
    param([Parameter(Mandatory = $true)]$Entities, [Parameter(Mandatory = $true)][int[]]$Root)
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'; $queue = New-Object System.Collections.Queue
    foreach ($start in $Root) { if ($seen.Add($start)) { $queue.Enqueue($start) } }
    while ($queue.Count -gt 0) {
        $entity = $null
        if (-not $Entities.TryGetValue([int]$queue.Dequeue(), [ref]$entity)) { continue }
        $bare = [regex]::Replace($entity.Body, "'(?:[^']|'')*'", "''")
        foreach ($reference in [regex]::Matches($bare, '#(\d+)')) { $next = [int]$reference.Groups[1].Value; if ($seen.Add($next)) { $queue.Enqueue($next) } }
    }
    return ,$seen
}

function Test-StepViewBlockConfinement {
    <# Do two exports of one part differ ONLY in the saved view? The view block is everything reachable from the
       CAMERA_MODEL_D3 instances (the camera's placement, its VIEW_VOLUME and the PLANAR_BOX of the view window).
       Confined means: both files have the same instances; every instance whose text differs lies in the view block
       of both files; and no instance outside the view block refers to a differing one. #>
    param([Parameter(Mandatory = $true)][string]$FirstPath, [Parameter(Mandatory = $true)][string]$OtherPath, [int]$MaxListed = 200)
    $difference = Compare-StepEntities -FirstPath $FirstPath -OtherPath $OtherPath -MaxListed 1000000
    $result = [ordered]@{ changed_count = $difference.changed_count; only_in_first_count = $difference.only_in_first_count; only_in_other_count = $difference.only_in_other_count; changed_by_type = $difference.changed_by_type
        view_block = $null; outside_view_block = @(); referenced_from_outside = @(); confined_to_view_block = $false; changed = @($difference.changed | Select-Object -First $MaxListed) }
    $changedIds = @($difference.changed | ForEach-Object { [int]$_.id })
    $blocks = @()
    foreach ($path in @($FirstPath, $OtherPath)) {
        $entities = Get-StepEntities -Path $path
        $cameras = @($entities.get_Values() | Where-Object { $_.Type -eq "CAMERA_MODEL_D3" } | ForEach-Object { [int]$_.Id })
        $closure = $(if ($cameras.Count) { Get-StepReferenceClosure -Entities $entities -Root $cameras } else { New-Object 'System.Collections.Generic.HashSet[int]' })
        $outside = @($changedIds | Where-Object { -not $closure.Contains($_) })
        $referrers = @()
        if ($changedIds.Count) {
            $wanted = New-Object 'System.Collections.Generic.HashSet[int]'; foreach ($id in $changedIds) { [void]$wanted.Add($id) }
            foreach ($entity in $entities.get_Values()) {
                if ($closure.Contains([int]$entity.Id) -or -not $entity.Body.Contains("#")) { continue }
                $bare = [regex]::Replace($entity.Body, "'(?:[^']|'')*'", "''")
                foreach ($reference in [regex]::Matches($bare, '#(\d+)')) { if ($wanted.Contains([int]$reference.Groups[1].Value)) { $referrers += "#$($entity.Id) $($entity.Type) -> #$($reference.Groups[1].Value)" } }
            }
        }
        $types = [ordered]@{}; foreach ($id in ($closure | Sort-Object)) { $member = $null; if ($entities.TryGetValue([int]$id, [ref]$member)) { $types[$member.Type] = 1 + [int]$types[$member.Type] } }
        $blocks += [ordered]@{ cameras = $cameras; entities = $closure.get_Count(); entity_types = $types; changed_outside = $outside; changed_referenced_from_outside = $referrers }
    }
    $result.view_block = [ordered]@{ first = $blocks[0]; other = $blocks[1] }
    $result.outside_view_block = @(@($blocks[0].changed_outside) + @($blocks[1].changed_outside) | Sort-Object -Unique)
    $result.referenced_from_outside = @(@($blocks[0].changed_referenced_from_outside) + @($blocks[1].changed_referenced_from_outside) | Sort-Object -Unique)
    $result.confined_to_view_block = ($difference.only_in_first_count -eq 0 -and $difference.only_in_other_count -eq 0 -and $result.outside_view_block.Count -eq 0 -and $result.referenced_from_outside.Count -eq 0 -and @($blocks[0].cameras).Count -gt 0 -and @($blocks[1].cameras).Count -gt 0)
    return $result
}

function Compare-StepEntities {
    <# Entity-level difference of two data sections, matched by entity id: instances whose type or text differs,
       and instances present in only one file. Lists at most -MaxListed of each, with the full counts. #>
    param([Parameter(Mandatory = $true)][string]$FirstPath, [Parameter(Mandatory = $true)][string]$OtherPath, [int]$MaxListed = 200)
    $first = Get-StepEntities -Path $FirstPath; $other = Get-StepEntities -Path $OtherPath
    $changed = New-Object System.Collections.ArrayList; $onlyFirst = New-Object System.Collections.ArrayList; $onlyOther = New-Object System.Collections.ArrayList
    foreach ($id in $first.get_Keys()) {
        $left = $first.get_Item($id); $right = $null
        if ($other.TryGetValue($id, [ref]$right)) { if ($left.Type -cne $right.Type -or $left.Body -cne $right.Body) { [void]$changed.Add([ordered]@{ id = $id; first_type = $left.Type; other_type = $right.Type; first = $left.Body; other = $right.Body }) } }
        else { [void]$onlyFirst.Add([ordered]@{ id = $id; type = $left.Type; text = $left.Body }) }
    }
    foreach ($id in $other.get_Keys()) { if (-not $first.ContainsKey($id)) { $right = $other.get_Item($id); [void]$onlyOther.Add([ordered]@{ id = $id; type = $right.Type; text = $right.Body }) } }
    $byType = [ordered]@{}
    foreach ($group in (@($changed) | Group-Object { "$($_.first_type)$(if ($_.first_type -cne $_.other_type) { ' -> ' + $_.other_type })" } | Sort-Object Count -Descending)) { $byType[$group.Name] = $group.Count }
    [ordered]@{ entities_first = $first.get_Count(); entities_other = $other.get_Count(); changed_count = $changed.Count; only_in_first_count = $onlyFirst.Count; only_in_other_count = $onlyOther.Count
        changed_by_type = $byType; changed = @($changed | Sort-Object { $_.id } | Select-Object -First $MaxListed)
        only_in_first = @($onlyFirst | Sort-Object { $_.id } | Select-Object -First $MaxListed); only_in_other = @($onlyOther | Sort-Object { $_.id } | Select-Object -First $MaxListed)
        listing_complete = ($changed.Count -le $MaxListed -and $onlyFirst.Count -le $MaxListed -and $onlyOther.Count -le $MaxListed) }
}
