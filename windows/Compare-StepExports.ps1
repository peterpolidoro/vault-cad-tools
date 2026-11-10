<#
.SYNOPSIS
Compare several STEP exports of the same part as text: are the data sections identical, which header lines
differ, and do the files become byte-identical once their headers are normalised? Offline; no CAD kernel.

.DESCRIPTION
    & .\windows\Compare-StepExports.ps1 -Path A.step,B.step,C.step -Label today-1,today-2,october -OutputPath NEW.json

For every file: size, SHA-256, the data-section SHA-256 (from the DATA keyword to the end of the file) and the
header fields. Every later file is compared with the first: whether the data sections are identical and which
header lines differ (line by line; both texts are listed). Each file is also normalised into a temporary
directory with Set-StepFileHeader (name part.step, time stamp 1970-01-01T00:00:00, empty author, organization
and authorisation), and the hashes of the normalised files are compared. Nothing is written beside the inputs.
The result goes to -OutputPath (refused if it exists) and to the pipeline. Exit code 1 when the data sections
differ.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string[]]$Label,
    [string]$OutputPath
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Step-Header.ps1")
if ($Path.Count -lt 2) { throw "Give at least two files" }
if ($Label -and $Label.Count -ne $Path.Count) { throw "-Label needs one entry per -Path" }
if ($OutputPath -and (Test-Path -LiteralPath $OutputPath)) { throw "Refusing to overwrite: $OutputPath" }
$temp = Join-Path $env:TEMP ("vault-cad-step-compare-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $files = @()
    for ($index = 0; $index -lt $Path.Count; $index++) {
        $info = Get-StepFileInfo -Path $Path[$index]
        $normalisedPath = Join-Path $temp "$index.step"
        $normalised = Set-StepFileHeader -Path $Path[$index] -OutPath $normalisedPath
        $files += [pscustomobject]@{ label = $(if ($Label) { $Label[$index] } else { "file-$($index + 1)" }); path = $Path[$index]; bytes = $info.bytes; sha256 = $info.sha256; data_sha256 = $info.data_sha256
            data_offset = $info.data_offset; data_bytes = ($info.bytes - $info.data_offset); header = $info.header; header_lines = $info.header_lines
            normalised_sha256 = $normalised.output_sha256; normalised_bytes = $normalised.output_bytes }
    }
    $first = $files[0]; $pairs = @()
    for ($index = 1; $index -lt $files.Count; $index++) {
        $other = $files[$index]; $differing = @()
        $lines = [Math]::Max($first.header_lines.Count, $other.header_lines.Count)
        for ($line = 0; $line -lt $lines; $line++) {
            $left = $(if ($line -lt $first.header_lines.Count) { $first.header_lines[$line] } else { $null }); $right = $(if ($line -lt $other.header_lines.Count) { $other.header_lines[$line] } else { $null })
            if ($left -cne $right) { $differing += [ordered]@{ line = $line + 1; first = $left; other = $right } }
        }
        $pairs += [ordered]@{ first = $first.label; other = $other.label; data_sections_identical = ($first.data_sha256 -eq $other.data_sha256); files_identical = ($first.sha256 -eq $other.sha256)
            normalised_files_identical = ($first.normalised_sha256 -eq $other.normalised_sha256); differing_header_lines = $differing }
    }
    $result = [ordered]@{ schema_version = 1; generated_at = [DateTime]::UtcNow.ToString("o"); files = @($files | ForEach-Object { [ordered]@{ label = $_.label; path = $_.path; bytes = $_.bytes; sha256 = $_.sha256; data_sha256 = $_.data_sha256; data_offset = $_.data_offset
                data_bytes = $_.data_bytes; header = $_.header; normalised_sha256 = $_.normalised_sha256; normalised_bytes = $_.normalised_bytes } })
        distinct_data_sha256 = @($files | ForEach-Object { $_.data_sha256 } | Sort-Object -Unique).Count; data_sections_identical = (@($files | ForEach-Object { $_.data_sha256 } | Sort-Object -Unique).Count -eq 1)
        distinct_normalised_sha256 = @($files | ForEach-Object { $_.normalised_sha256 } | Sort-Object -Unique).Count; normalised_files_identical = (@($files | ForEach-Object { $_.normalised_sha256 } | Sort-Object -Unique).Count -eq 1)
        differing_header_line_numbers = @($pairs | ForEach-Object { $_.differing_header_lines | ForEach-Object { $_.line } } | Sort-Object -Unique); pairs = $pairs }
    if ($OutputPath) { ConvertTo-Json -InputObject $result -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
    $result
    if (-not $result.data_sections_identical) { exit 1 }
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
