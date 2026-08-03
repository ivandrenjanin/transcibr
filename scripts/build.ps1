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

	Invoke-Odin -Odin $odin -Arguments $arguments
	$odinExit = $LASTEXITCODE
	if ($odinExit -ne 0) {
		throw "odin exited $odinExit building $($target.Name)."
	}

	# Read out of the image rather than trusted from the flag that went in.
	Assert-PeSubsystem -Path $out -Subsystem $target.Subsystem
	Write-Host "-> $out is subsystem $($target.Subsystem)" -ForegroundColor Green

	if ($target.Smoke) {
		$smoke = Read-NativeOutput -Command $out -Arguments @()
		if ($smoke.ExitCode -ne 0) {
			throw "$($target.Name) exited $($smoke.ExitCode), expected 0."
		}
		if ($smoke.Output -notmatch "^$([regex]::Escape($target.Name)) \d+\.\d+\.\d+$") {
			throw "$($target.Name) did not report a version; printed '$($smoke.Output)'."
		}
		Write-Host "-> $($target.Name) printed: $($smoke.Output)" -ForegroundColor Green
	}
}

Write-Host ''
Write-Host "Built $($OdinTargets.Count) target(s) into $BuildRoot" -ForegroundColor Green

# Stated, not inherited from whichever native command happened to run last.
exit 0
