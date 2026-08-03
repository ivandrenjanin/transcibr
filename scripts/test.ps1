# The test command.
#
#   .\scripts\test.ps1
#   .\scripts\test.ps1 -TestName version.banner_names_the_program_and_its_version
#
# `odin test` collects test procedures from a SINGLE package. Naming one
# package is therefore not a test command: the moment the code spans several,
# the ones not named stop being run and nothing says so. Worse, `odin test` on
# a package with no tests prints "No tests to run." and exits 0 -- so a sweep
# that only checks exit codes reports success having run nothing at all.
#
# This script exists to close both holes. It discovers every package under
# src\, runs each one, and reads the runner's own JSON report to see what each
# package actually collected. A package that collects nothing fails unless it
# is named in $OdinPackagesWithoutTests; a package named there that collects
# something fails too. A per-package check, not a total: a total stops guarding
# anything the moment a second package has tests.
#
# Checks on the sweep itself live in scripts\selftest.ps1.

[CmdletBinding()]
param(
	# Run one test instead of sweeping, as <package>.<test>. Only that
	# package is built, and a name that matches nothing is a failure.
	[string] $TestName = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

# No terminating error may leave a zero exit behind. That is how this script
# once reported success after crashing before its own failure check.
trap {
	Write-Host ''
	Write-Host "TEST COMMAND FAILED: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}

$odin = Resolve-OdinCompiler
Write-Host "Odin: $odin ($OdinVersionPin)"

$packages = @(Get-OdinPackage)
if ($packages.Count -eq 0) {
	Write-Host ''
	Write-Host "TEST COMMAND FAILED: no Odin packages found under $SrcRoot." -ForegroundColor Red
	exit 1
}

$focused = ($TestName -ne '')
if ($focused) {
	$wanted = $TestName.Split('.')[0]
	$packages = @($packages | Where-Object { ($_.Name -split '/')[-1] -eq $wanted })
	if ($packages.Count -eq 0) {
		Write-Host ''
		Write-Host "TEST COMMAND FAILED: no package '$wanted' under $SrcRoot." -ForegroundColor Red
		Write-Host '-TestName takes <package>.<test>.' -ForegroundColor Red
		exit 1
	}
}

# The test executables and the runner's reports both land here. Space-free
# because `odin test` runs the binary it builds through an unquoted command
# line -- see Get-SpaceFreeDirectory.
$testRoot = Get-SpaceFreeDirectory -Path (Join-Path $BuildRoot 'odin-test')

$failures = @()
$totalTests = 0

foreach ($package in $packages) {
	Write-Host ''
	Write-Host "=== $($package.Name) ===" -ForegroundColor Cyan

	$stem = Join-Path $testRoot $package.Name.Replace('/', '-')
	$report = "$stem.json"
	if (Test-Path -LiteralPath $report) {
		Remove-Item -LiteralPath $report -Force
	}

	# ODIN_TEST_TRACK_MEMORY defaults true but ODIN_TEST_FAIL_ON_BAD_MEMORY
	# defaults FALSE, so without this a procedure that leaks its returned
	# slice is reported as a warning and the test still passes (ADR-0010).
	$arguments = @(
		'test'
		$package.Path
		$OdinCollection
		"-out:$stem.exe"
		"-define:ODIN_TEST_JSON_REPORT=$report"
		'-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true'
	) + $OdinVetFlags
	if ($focused) {
		$arguments += "-define:ODIN_TEST_NAMES=$TestName"
	}

	# Invoked directly, never through cmd: hand-quoting a flag string breaks on
	# the first checkout path containing a space, and PowerShell's own argument
	# passing does not. Nothing is redirected either, so the runner's output
	# reaches the console as it happens and $LASTEXITCODE stays trustworthy.
	Invoke-Odin -Odin $odin -Arguments $arguments
	$odinExit = $LASTEXITCODE

	# The runner's machine-readable report, not its console prose. It writes no
	# file at all when it collects nothing, which is itself the answer.
	$collected = 0
	$succeeded = 0
	if (Test-Path -LiteralPath $report) {
		$json = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
		$collected = [int] $json.total
		$succeeded = [int] $json.success
	}
	$totalTests += $collected

	$expectedEmpty = ($OdinPackagesWithoutTests -contains $package.Name)
	if ($odinExit -ne 0) {
		$failures += "$($package.Name): odin exited $odinExit"
		Write-Host "-> FAILED (odin exited $odinExit)" -ForegroundColor Red
	}
	elseif ($succeeded -ne $collected) {
		$failures += "$($package.Name): $($collected - $succeeded) of $collected tests failed but odin exited 0"
		Write-Host "-> FAILED ($succeeded of $collected succeeded)" -ForegroundColor Red
	}
	elseif ($collected -eq 0) {
		if ($focused) {
			$failures += "$($package.Name): no test named '$TestName'"
			Write-Host "-> FAILED (no test named '$TestName')" -ForegroundColor Red
		}
		elseif ($expectedEmpty) {
			Write-Host '-> no tests, as declared in $OdinPackagesWithoutTests' -ForegroundColor DarkGray
		}
		else {
			$failures += "$($package.Name): collected ZERO tests"
			Write-Host '-> FAILED (collected ZERO tests)' -ForegroundColor Red
		}
	}
	elseif ($expectedEmpty -and (-not $focused)) {
		$failures += "$($package.Name): collected $collected tests but is listed in `$OdinPackagesWithoutTests"
		Write-Host "-> FAILED (declared test-less, collected $collected)" -ForegroundColor Red
	}
	else {
		Write-Host "-> $collected passed" -ForegroundColor Green
	}
}

Write-Host ''
Write-Host '========================================'
Write-Host "Packages swept: $($packages.Count)"
Write-Host "Tests run:      $totalTests"

# The loud failure. Every path that leads here -- a renamed attribute, a
# package that stopped being discovered, a runner that silently collected
# nothing -- looks like a clean pass to a command that only checks exit codes.
if ($failures.Count -gt 0) {
	Write-Host ''
	Write-Host "TEST COMMAND FAILED in $($failures.Count) package(s):" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host "  - $failure" -ForegroundColor Red
	}
	Write-Host 'A test run that executes nothing is a failure, not a pass.' -ForegroundColor Red
	exit 1
}

Write-Host ''
Write-Host "All $totalTests tests passed." -ForegroundColor Green

# Stated, not inherited. Falling off the end leaves $LASTEXITCODE holding
# whatever the last native command set, which is the compiler's answer to one
# package rather than this script's answer to the sweep.
exit 0
