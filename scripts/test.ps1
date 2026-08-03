# The test command.
#
#   .\scripts\test.ps1
#
# `odin test` collects test procedures from a SINGLE package. Naming one
# package is therefore not a test command: the moment the code spans several,
# the ones not named stop being run and nothing says so. Worse, `odin test` on
# a package with no tests prints "No tests to run." and exits 0 -- so a sweep
# that only checks exit codes reports success having run nothing at all.
#
# This script exists to close both holes. It discovers every package under
# src/, runs each one, counts the tests the runner reports actually finishing,
# and fails when that total is zero.
#
# To run a single test, call the compiler directly:
#
#   C:\Odin\dist\odin.exe test src\version -collection:transcibr=src `
#       -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do `
#       -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true `
#       -define:ODIN_TEST_NAMES=version.banner_names_the_program_and_its_version

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')

$odin = Resolve-OdinCompiler
Write-Host "Odin: $odin"

$packages = Get-OdinPackage
if (-not $packages) {
	Write-Host ''
	Write-Host "TEST COMMAND FAILED: no Odin packages found under $SrcRoot." -ForegroundColor Red
	exit 1
}

# ODIN_TEST_TRACK_MEMORY defaults true but ODIN_TEST_FAIL_ON_BAD_MEMORY
# defaults FALSE, so without this a procedure that leaks its returned slice is
# reported as a warning and the test still passes (ADR-0010).
$testFlags = @(
	$OdinCollection
	'-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true'
) + $OdinVetFlags

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "transcibr-test-$PID.log"
$totalTests = 0
$failedPackages = @()

foreach ($package in $packages) {
	$relative = $package.Substring($RepoRoot.Length).TrimStart('\', '/')
	Write-Host ''
	Write-Host "=== $relative ===" -ForegroundColor Cyan

	# The runner writes its log and summary to stderr but "No tests to run." to
	# stdout, so both streams are needed. cmd does the redirect because
	# PowerShell 5.1 wraps a native command's stderr in ErrorRecords and would
	# set $? false on a clean exit.
	$quoted = ($testFlags | ForEach-Object { '"' + $_ + '"' }) -join ' '
	& cmd /c "`"$odin`" test `"$package`" $quoted > `"$scratch`" 2>&1"
	$odinExit = $LASTEXITCODE

	$output = if (Test-Path -LiteralPath $scratch) { Get-Content -LiteralPath $scratch -Raw } else { '' }
	if ($output) {
		Write-Host $output.TrimEnd()
	}

	# "Finished 3 tests in 3.8ms." -- the runner counting what it actually ran.
	# Counting @(test) procedures in the source instead would prove only that
	# they were written, not that anything executed them.
	$finished = [regex]::Match($output, 'Finished\s+(\d+)\s+tests?\s+in\s')
	$packageTests = if ($finished.Success) { [int] $finished.Groups[1].Value } else { 0 }
	$totalTests += $packageTests

	if ($odinExit -ne 0) {
		$failedPackages += $relative
		Write-Host "-> FAILED (odin exited $odinExit)" -ForegroundColor Red
	}
	elseif ($packageTests -eq 0) {
		Write-Host '-> no tests in this package' -ForegroundColor DarkGray
	}
	else {
		Write-Host "-> $packageTests passed" -ForegroundColor Green
	}
}

if (Test-Path -LiteralPath $scratch) {
	Remove-Item -LiteralPath $scratch -Force
}

Write-Host ''
Write-Host '========================================'
Write-Host "Packages swept: $($packages.Count)"
Write-Host "Tests run:      $totalTests"

if ($failedPackages.Count -gt 0) {
	Write-Host ''
	Write-Host "TESTS FAILED in $($failedPackages.Count) package(s):" -ForegroundColor Red
	foreach ($failure in $failedPackages) {
		Write-Host "  - $failure" -ForegroundColor Red
	}
	exit 1
}

# The loud failure. Every path that leads here -- a renamed attribute, a
# package that stopped being discovered, a runner that silently collected
# nothing -- looks like a clean pass to a command that only checks exit codes.
if ($totalTests -eq 0) {
	Write-Host ''
	Write-Host 'TEST COMMAND FAILED: swept every package and discovered ZERO tests.' -ForegroundColor Red
	Write-Host 'A test run that executes nothing is a failure, not a pass.' -ForegroundColor Red
	exit 1
}

Write-Host ''
Write-Host "All $totalTests tests passed." -ForegroundColor Green
