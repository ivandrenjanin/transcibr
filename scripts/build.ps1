# The build command.
#
#   .\scripts\build.ps1
#   .\scripts\build.ps1 -Configuration release
#
# Produces every binary in $OdinTargets under the full vet set with warnings as
# errors, then verifies each one: the subsystem recorded in its PE header
# (ADR-0004) and, for a target that can be run headless, that it starts and
# reports its version. Those checks live here rather than in CI because a
# developer who breaks them should find out from the build command, not from a
# red pipeline half an hour later.

[CmdletBinding()]
param(
	# debug builds with symbols for a debugger; release optimises for speed.
	# CI runs both, so neither configuration rots.
	[ValidateSet('debug', 'release')]
	[string] $Configuration = 'debug'
)

. (Join-Path $PSScriptRoot 'common.ps1')

trap {
	Write-Host ''
	Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}

$odin = Resolve-OdinCompiler
Write-Host "Odin:   $odin ($OdinVersionPin)"

# -Optional, so a contributor who has the pinned compiler but not the ols zip
# can still build. A formatter whose build did not match the pin already warned
# and carried on; one that was not installed at all failed the build outright,
# and there is no reading of the pin argument under which those differ. CI
# installs the formatter and refuses to skip anything, so rule S1 is still
# enforced against the branch either way.
$odinfmt = Resolve-OdinFormatter -Optional
Write-Host "Build:  $Configuration"

if ($odinfmt -eq '') {
	Write-Host 'Format: NOT CHECKED -- no odinfmt (see the warning above)' -ForegroundColor Yellow
}
else {
	Write-Host "Format: $odinfmt (ols $OdinfmtReleaseTag)"

	# CLAUDE.md rule S1's other half, and it fails the build for the same reason
	# the vet flags below do: a rule enforced only at review is a rule that
	# reaches main. Before the compiler runs, so the answer arrives in a second
	# rather than after every target has been linked. scripts\format.ps1 -Fix is
	# the way out.
	Assert-OdinFormatting -Odinfmt $odinfmt
	Write-Host '-> every .odin file is formatted as odinfmt.json says' -ForegroundColor Green
}

# THE BOOTSTRAP, and it happens here because this is where it has to.
#
# The four source policies below read Odin with tools\policy, an Odin program
# (ADR-0028), so the checker has to be built before it can be asked about the tree
# that contains it -- including about its own source, which Get-OdinSource
# discovers like any other. Resolve-OdinPolicyTool is what builds it: from
# tools\policy under the same vet set as every target below, or from an
# already-built one where $env:TRANSCIBR_POLICY names it, which is how
# scripts\selftest.ps1 runs thirty fixture builds without compiling it thirty
# times.
#
# A checker that does not build stops the build HERE, with the compiler's own
# diagnostics above and nothing claimed about the tree. The state to avoid is the
# other one: a build reporting four policy verdicts it never reached.
#
# tools\policy carries its own tests and is NOT in $OdinPackagesWithoutTests --
# it reads Odin, so it can be tested in Odin, and .\scripts\test.ps1 sweeps it
# like any package under src\.
$policy = Resolve-OdinPolicyTool
Write-Host "Policy: $policy"

# READ ONCE, for all four policies below.
#
# Each of them reads the tree for itself when it is handed nothing -- a walk for
# discovery and a child process to read what it found -- which is four of each per
# build over one tree that cannot change in between. Measured over this
# repository: 487ms for the four, against 456ms to compile the whole product.
#
# Not a memo, and specifically not one keyed on timestamps: see Get-OdinSourceFact
# for why that is unsafe here. This is one read passed to four callers, so there
# is nothing cached and nothing to invalidate, and every other caller of the four
# -- scripts\selftest.ps1's cases -- passes nothing and reads afresh.
$sources = Get-OdinCheckedSource
$facts = Get-OdinSourceFact -Sources $sources

# CLAUDE.md rule F1: a hard limit on one procedure, measured from the line
# carrying `::` through the closing brace.
Assert-OdinProcedureLength -Facts $facts
Write-Host "-> no .odin procedure is over $OdinProcedureLineLimit lines" -ForegroundColor Green

# CLAUDE.md section 0, checked whether or not a formatter was found: this needs
# the checker above and nothing else, so there is no configuration in which the
# comment ban goes unenforced while the build still runs. Before the compiler,
# like the check above and for the same reason -- the answer arrives in a second
# rather than after every target has been linked.
Assert-OdinCommentPolicy -Facts $facts
Write-Host '-> no .odin procedure body carries a comment' -ForegroundColor Green

# CLAUDE.md rule F2, in the same place and for the same reason. The attribute
# itself is what fails the compile at a call site that drops an answer; what
# nothing else covers is the procedure declared tomorrow without it, and a rule
# nothing checks is the direction every bare one arrived from (issue #43).
#
# Order does not carry anything here. The read above refuses a file it could not
# read before any of the four is asked anything, so none of them is complete only
# because another ran first.
Assert-OdinResultPolicy -Facts $facts
Write-Host '-> every .odin procedure that returns carries @(require_results)' -ForegroundColor Green

# CLAUDE.md rule M2, and the one of the four whose absence the compiler cannot
# report. The tag is what makes ADR-0010 a compile error, and it is read per file:
# an untagged file builds with its implicit allocators unchecked however many of
# its siblings carry it. A misspelling or a misplaced tag already fails the
# compile below and names the file; only a tag nobody wrote is silent.
Assert-OdinVetTagPolicy -Facts $facts
Write-Host "-> every .odin file declares the #+vet names it is scoped for ($(($OdinFileVetTags | ForEach-Object { $_.Name }) -join ' '))" -ForegroundColor Green

# README.md's Network access claim (issue #58), the fifth verdict over the same
# file list and the only one that is not one of CLAUDE.md's four source
# policies: it answers a literal substring rather than a structural question,
# so it reads the sources directly rather than through tools\policy's facts.
Assert-OdinNetworkConfinement -Sources $sources
Write-Host "-> '$OdinNetworkCodeName' is confined to $OdinNetworkCodeRelativeName, if it appears in src\ at all" -ForegroundColor Green

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null

# Counted as each target is finished, not taken from $OdinTargets afterwards:
# a total read off the list reports what was DECLARED however little ran.
$built = 0

foreach ($target in $OdinTargets) {
	$out = Join-Path $BuildRoot "$($target.Name).exe"

	$arguments = @(
		'build'
		(Join-Path $SrcRoot $target.Package)
		$OdinCollection
		"-out:$out"
		"-subsystem:$($target.Subsystem)"
	) + $OdinVetFlags

	if ($Configuration -eq 'release') {
		$arguments += '-o:speed'
	}
	else {
		$arguments += '-debug'
	}

	Write-Host ''
	Write-Host "=== $($target.Name) ($($target.Subsystem)) ===" -ForegroundColor Cyan

	# Under the same ceiling the sweep runs: a compiler that never returns is
	# the identical unguarded wait, and this command has no timeout of its own
	# either -- see $OdinCommandTimeoutSeconds.
	$run = Invoke-NativeCommand -Command $odin -Arguments $arguments -TimeoutSeconds $OdinCommandTimeoutSeconds
	if ($run.TimedOut) {
		throw "odin did not finish building $($target.Name) within $OdinCommandTimeoutSeconds seconds and was killed."
	}
	if ($run.ExitCode -ne 0) {
		throw "odin exited $($run.ExitCode) building $($target.Name)."
	}

	# Read out of the image rather than trusted from the flag that went in.
	Assert-PeSubsystem -Path $out -Subsystem $target.Subsystem
	Write-Host "-> $out is subsystem $($target.Subsystem)" -ForegroundColor Green

	if ($target.Smoke) {
		# Under the same ceiling as the compiler that produced it. A `main` that
		# wedges is this command never coming back, with nothing but the CI job's
		# own timeout behind it -- and that is not a backstop a developer has.
		$smoke = Read-NativeOutput -Command $out -Arguments @() -TimeoutSeconds $OdinCommandTimeoutSeconds
		if ($smoke.TimedOut) {
			throw "$($target.Name) did not finish within $OdinCommandTimeoutSeconds seconds and was killed."
		}
		if ($smoke.ExitCode -ne 0) {
			throw "$($target.Name) exited $($smoke.ExitCode), expected 0."
		}
		if ($smoke.Output -notmatch "^$([regex]::Escape($target.Name)) \d+\.\d+\.\d+$") {
			throw "$($target.Name) did not report a version; printed '$($smoke.Output)'."
		}
		Write-Host "-> $($target.Name) printed: $($smoke.Output)" -ForegroundColor Green
	}

	$built += 1
}

Write-Host ''
if ($built -eq 0) {
	throw "no targets built: `$OdinTargets in scripts\common.ps1 is empty."
}
Write-Host "Built $built target(s) into $BuildRoot" -ForegroundColor Green

# Stated, not inherited from whichever native command happened to run last.
exit 0
