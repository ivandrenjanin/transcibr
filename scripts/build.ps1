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
Write-Host "Build:  $Configuration"

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
