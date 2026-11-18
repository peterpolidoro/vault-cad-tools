<#
.SYNOPSIS
What a row that the Vault Data API lists as a file version is: a version checked in, or the place of a check-out.
Pure: it sends nothing and reads no file.

.DESCRIPTION
Dot-source it:
    . (Join-Path $PSScriptRoot "Vault-Version.ps1")

Observed on this server on 2026-11-17 (Vault 2025, API 2.0.16). A file that is checked out is listed with a row
of its own above its versions: the version number is one above the last version checked in, and checkinDate is
0001-01-01T00:00:00Z. That row is the place of the check-out, not a version checked in: nothing was checked in
under its id, and what its content and its associations are is whatever the server holds for a check-out in
progress. folders/{id}/contents names a checked-out file by that row, files/{master}/versions lists it last, and
/parents names a checked-out parent by it (/uses was not seen with a checked-out child; it is read the same way).

isCheckedOut does NOT tell the two apart: it is true on every row of a checked-out file, on the versions that
were checked in before as well. The check-in date does.

    checked_in         the date reads as a date after year 1
    check_out_place    the date reads as a date of year 1
    no_check_in_date   there is no date, or it cannot be read as one: not known to be a version checked in
#>

function Get-VaultVersionStanding {
    param($CheckinDate)
    if ($null -eq $CheckinDate) { return "no_check_in_date" }
    $year = $null
    if ($CheckinDate -is [DateTime] -or $CheckinDate -is [DateTimeOffset]) { $year = $CheckinDate.Year }
    else {
        $text = ([string]$CheckinDate).Trim()
        if (-not $text) { return "no_check_in_date" }
        $parsed = [DateTimeOffset]::MinValue
        # DateTimeOffset, not DateTime: a DateTime of year 1 with a "Z" cannot be turned into local time west of Greenwich.
        if (-not [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return "no_check_in_date" }
        $year = $parsed.Year
    }
    if ($year -le 1) { return "check_out_place" }
    return "checked_in"
}

function Get-VaultCheckinDate {
    <# The check-in date to record for a row: the date as the server gave it for a version checked in, and nothing
       for any other row. A date of year 1 is not a date anything was checked in. #>
    param($CheckinDate)
    if ((Get-VaultVersionStanding $CheckinDate) -eq "checked_in") { return $CheckinDate }
    return $null
}
