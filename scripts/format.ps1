# The formatting command.
#
#   .\scripts\format.ps1        # report every file odinfmt would rewrite
#   .\scripts\format.ps1 -Fix   # rewrite them
#
# CLAUDE.md rule S1 is "odinfmt, tabs, the full vet set". The vet set is passed
# by build.ps1 and test.ps1 and fails the build; this is the other half, and it
# fails the build too -- build.ps1 calls the same sweep, so a misformatted file
# is caught by the command a developer already runs rather than at review.
#
# The style itself is odinfmt.json at the repository root, which is also the
# name odinfmt looks for on its own: an editor formatting on save and this
# command cannot disagree.
#
# Checks on this sweep live in scripts\selftest.ps1, alongside the checks on the
# other two.

[CmdletBinding()]
param(
	# Rewrite the misformatted files instead of only naming them.
	[switch] $Fix
)

. (Join-Path $PSScriptRoot 'common.ps1')

# No terminating error may leave a zero exit behind -- the trap test.ps1 carries,
# for the reason it carries it.
trap {
	Write-Host ''
	Write-Host "FORMAT COMMAND FAILED: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}

$odinfmt = Resolve-OdinFormatter
Write-Host "odinfmt: $odinfmt (ols $OdinfmtReleaseTag)"
Write-Host "Style:   $OdinFormatConfig"

$misformatted = @(Get-MisformattedOdinSource -Odinfmt $odinfmt)

# Reported whatever the verdict, because the interesting failure is a sweep that
# looked at nothing. Get-MisformattedOdinSource throws on zero files; this is the
# number a reader can check against what they expected to be covered.
$total = @(Get-OdinSource).Count
Write-Host ''
Write-Host "Files checked: $total"

if ($misformatted.Count -eq 0) {
	Write-Host ''
	Write-Host "All $total .odin files are formatted as odinfmt.json says." -ForegroundColor Green
	exit 0
}

foreach ($file in $misformatted) {
	if ($Fix) {
		# The bytes the sweep already computed, written whole. Not `odinfmt -w`,
		# which renames the original to `<name>_bk` and removes it only after the
		# write succeeds -- an interrupted run leaves that backup behind, and a
		# `_bk` file is neither source nor artefact and is ignored by nothing.
		# Writing what the check compared against also makes it impossible for the
		# fix and the check to disagree about what the answer was.
		[System.IO.File]::WriteAllBytes($file.Path, $file.Formatted)
		Write-Host "-> rewrote $($file.Name)" -ForegroundColor Green
	}
	else {
		Write-Host "-> $($file.Name)" -ForegroundColor Red
	}
}

Write-Host ''
if ($Fix) {
	Write-Host "Rewrote $($misformatted.Count) of $total file(s)." -ForegroundColor Green
	# Stated, not inherited from whichever native command happened to run last.
	exit 0
}

Write-Host "FORMAT COMMAND FAILED: $($misformatted.Count) of $total file(s) are not formatted as odinfmt.json says (CLAUDE.md rule S1)." -ForegroundColor Red
Write-Host 'Run .\scripts\format.ps1 -Fix to rewrite them.' -ForegroundColor Red
exit 1
