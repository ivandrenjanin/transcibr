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
	[string] $TestName = '',

	# Wall-clock ceiling on ONE package's `odin test`, in seconds. Zero takes
	# $OdinCommandTimeoutSeconds from scripts\common.ps1, which is the answer
	# everywhere but scripts\selftest.ps1: it plants packages built to hang, and
	# cannot wait ten minutes to find out that they did. Resolved after the
	# dot-source below, because a param default is bound before it runs.
	#
	# The sweep as a whole is bounded separately, by $OdinSweepTimeoutSeconds:
	# this number times however many packages exist is not a ceiling anyone chose.
	[ValidateRange(0, 86400)]
	[int] $TimeoutSeconds = 0
)

. (Join-Path $PSScriptRoot 'common.ps1')

if ($TimeoutSeconds -eq 0) {
	$TimeoutSeconds = $OdinCommandTimeoutSeconds
}

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
	throw "no Odin packages found under $SrcRoot."
}

$focused = ($TestName -ne '')
if ($focused) {
	$wanted = $TestName.Split('.')[0]
	$packages = @($packages | Where-Object { ($_.Name -split '/')[-1] -eq $wanted })
	if ($packages.Count -eq 0) {
		throw "no package '$wanted' under $SrcRoot. -TestName takes <package>.<test>."
	}
}

# The test executables and the runner's reports both land here, in a directory
# chosen space-free and swept of what earlier runs left -- see Get-OdinTestRoot.
$testRoot = Get-OdinTestRoot

# The ceiling on the sweep as a whole and not merely on each package in it --
# see $OdinSweepTimeoutSeconds for why the product of the two was not one.
# Never below the per-package ceiling, so a caller who raises -TimeoutSeconds
# past it is not silently capped at it instead.
$sweepSeconds = [math]::Max($TimeoutSeconds, $OdinSweepTimeoutSeconds)
$sweepEnd = (Get-Date).AddSeconds($sweepSeconds)

$failures = @()
$totalTests = 0
$position = 0

foreach ($package in $packages) {
	Write-Host ''
	Write-Host "=== $($package.Name) ===" -ForegroundColor Cyan
	$position += 1

	# What is left of the sweep's own budget, which is what this package gets if
	# that is less than its own ceiling. A package left with none of it is not
	# started: a run nobody waits for cannot be reported, and naming the package
	# that would have gone next is the only thing left pointing anywhere.
	$remaining = [int][math]::Floor(($sweepEnd - (Get-Date)).TotalSeconds)
	if ($remaining -lt 1) {
		$failures += "$($package.Name): the sweep's $sweepSeconds-second budget ran out before this package ran"
		Write-Host "-> FAILED (the sweep's $sweepSeconds-second budget ran out)" -ForegroundColor Red
		continue
	}
	$budget = [math]::Min($TimeoutSeconds, $remaining)

	# The stem every artefact of this package's run is named from. Two
	# properties, neither optional:
	#
	# No space, whatever the package DIRECTORY is called: exactly the defect
	# Get-OdinTestRoot documents for the checkout path, reintroduced one
	# directory further down by naming the stem after src\my pkg\.
	#
	# Unique to this run. Two sweeps in one checkout share $testRoot, and on a
	# name fixed by package alone each deletes the report the other is about to
	# write and reads back "collected ZERO tests". $position also keeps the
	# sanitised names apart: `a b` and `a-b` sanitise to the same slug.
	$slug = $package.Name -replace '[^A-Za-z0-9._-]', '-'
	$stem = Join-Path $testRoot "$PID-$position-$slug"
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

	# Under a ceiling, because `odin test` RUNS what it builds and the runner
	# hangs outright when two or more tests assert concurrently -- see
	# $OdinCommandTimeoutSeconds. Nothing is redirected, so the runner's output
	# still reaches the console as it happens.
	$run = Invoke-NativeCommand -Command $odin -Arguments $arguments -TimeoutSeconds $budget
	$odinExit = $run.ExitCode

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

	# Read, so done with. Per-run names keep concurrent sweeps apart but would
	# otherwise leave one executable per package per run behind forever. Best
	# effort: a file another process still holds is not this sweep's verdict.
	Get-ChildItem -LiteralPath $testRoot -File -Filter "$PID-$position-$slug.*" -ErrorAction SilentlyContinue |
		Remove-Item -Force -ErrorAction SilentlyContinue

	$expectedEmpty = ($OdinPackagesWithoutTests -contains $package.Name)
	# Read before anything else, because a run that was killed left no verdict
	# to read: no summary, no JSON report, and an exit code that belongs to the
	# kill rather than to the tests. Named against the package, since that is
	# the only thing left pointing at what to go and look at.
	if ($run.TimedOut) {
		$failures += "$($package.Name): odin test did not finish within $budget seconds and was killed"
		Write-Host "-> FAILED (did not finish within $budget seconds; killed)" -ForegroundColor Red
	}
	elseif ($odinExit -ne 0) {
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
