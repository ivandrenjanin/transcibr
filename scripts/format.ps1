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
	[switch] $Fix,

	# Wall-clock ceiling on the WHOLE sweep, in seconds. Zero takes
	# $OdinSweepTimeoutSeconds from scripts\common.ps1, which is the answer
	# everywhere but scripts\selftest.ps1 -- it has to prove the budget is
	# enforced, and cannot wait fifteen minutes to find out that it is. Each
	# FILE is bounded separately by $OdinCommandTimeoutSeconds; this is the
	# ceiling on all of them together, which the product of the two was not.
	[ValidateRange(0, 86400)]
	[int] $SweepTimeoutSeconds = 0
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($SweepTimeoutSeconds -eq 0) {
	$SweepTimeoutSeconds = $OdinSweepTimeoutSeconds
}

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

$report = Get-OdinFormatReport -Odinfmt $odinfmt -SweepTimeoutSeconds $SweepTimeoutSeconds
$misformatted = @($report.Misformatted)

# Reported whatever the verdict, because the interesting failure is a sweep that
# looked at nothing. Get-OdinFormatReport throws on zero files; this is the
# number a reader can check against what they expected to be covered. Taken from
# the sweep rather than from a second walk of the repository, so the count and
# the verdict cannot come from two different answers to the same question.
$total = $report.Total
Write-Host ''
Write-Host "Files checked: $total"

if ($misformatted.Count -eq 0) {
	Write-Host ''
	Write-Host "All $total .odin files are formatted as odinfmt.json says." -ForegroundColor Green
	exit 0
}

foreach ($file in $misformatted) {
	if ($Fix) {
		# The bytes the sweep already computed, so the fix and the check cannot
		# disagree about what the answer was -- and swapped in rather than written
		# over. See Write-FileAtomically for why neither `odinfmt -w` nor a plain
		# WriteAllBytes is the way to put them there.
		Write-FileAtomically -Path $file.Path -Bytes $file.Formatted
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
