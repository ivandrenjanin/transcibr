# Self-test for the build and test commands.
#
#   .\scripts\selftest.ps1
#
# The sweep in test.ps1 is the one script whose failure mode is silence: every
# bug it has shipped so far reported success having run nothing. Checking it by
# hand is exactly the discipline that let those bugs through, so the checks live
# here instead.
#
# Each case plants a throwaway repository -- a copy of scripts\ next to a
# hand-built src\ -- runs the real test.ps1 inside it as a separate process, and
# asserts on the exit code and the output. Nothing here touches the real src\.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "transcibr-selftest-$PID"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Failures = @()
$script:Skips = @()
$script:Passes = 0

# "A test run that executes nothing is a failure, not a pass" -- the thesis of
# the script this file guards, turned on this file. Both values are DECLARED
# rather than counted from the cases that happened to run, because a count
# taken from what ran cannot notice that nothing did: deleting a case, or
# breaking the setup every case shares, then reads as a clean sweep of the
# cases that survived.
#
# Keep $ExpectedCaseCount in step with the cases below; a mismatch either way
# fails the run. Skipping is deny-by-default, same as $OdinPackagesWithoutTests
# in common.ps1: a case may end in a skip only if it is named here.
$ExpectedCaseCount = 14
$CasesAllowedToSkip = @(
	'an unreadable directory fails discovery rather than shortening it'
)

# A skip is signalled by throwing THIS OBJECT and nothing else, matched on
# reference identity of an instance private to this file.
#
# Not an exception type: PowerShell raises ItemNotFoundException for any
# missing path -- Copy-Item, Get-Item, Get-Content -- so a type-matched signal
# reads a broken fixture setup as an intentional skip. That is not theoretical.
# Deleting scripts\build.ps1 turned all twelve cases into skips and the run
# still exited 0, announcing that all zero cases passed.
$SkipSignal = [pscustomobject]@{ Reason = '' }

# ---------------------------------------------------------------- fixtures --

function New-FixtureRepo {
	param([Parameter(Mandatory)] [string] $Name)

	$root = Join-Path $FixtureRoot $Name
	if (Test-Path -LiteralPath $root) {
		Remove-Item -LiteralPath $root -Recurse -Force
	}
	$scripts = Join-Path $root 'scripts'
	New-Item -ItemType Directory -Path $scripts -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
	Copy-Item -Path (Join-Path $ScriptRoot 'common.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'test.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'build.ps1') -Destination $scripts -Force
	return $root
}

# Odin source, written ASCII/no-BOM with tab indentation so the fixtures pass
# the same vet set as the real packages.
function Add-FixturePackage {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [ValidateSet('passing', 'failing', 'leaking', 'none')] [string] $Test,
		# The directory to plant the package in, where that has to differ from
		# the package name: an Odin identifier cannot contain a space and a
		# directory can, which is the whole point of the case that uses this.
		[string] $Directory = '',
		[switch] $Hidden
	)

	if ($Directory -eq '') {
		$Directory = $Name
	}
	$dir = Join-Path (Join-Path $RepoRoot 'src') $Directory
	New-Item -ItemType Directory -Path $dir -Force | Out-Null

	$body = switch ($Test) {
		'passing' { "import `"core:testing`"`n`n@(test)`n${Name}_passes :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n}`n" }
		'failing' { "import `"core:testing`"`n`n@(test)`n${Name}_fails :: proc(t: ^testing.T) {`n`ttesting.expect(t, false, `"deliberate failure`")`n}`n" }
		'leaking' { "import `"core:testing`"`n`n@(test)`n${Name}_leaks :: proc(t: ^testing.T) {`n`tleaked := make([]u8, 8, context.allocator)`n`ttesting.expect(t, len(leaked) == 8)`n}`n" }
		'none' { "${Name}_CONSTANT :: 1`n" }
	}
	$source = "package $Name`n`n$body"
	[System.IO.File]::WriteAllText((Join-Path $dir "$Name.odin"), $source, $Utf8NoBom)

	if ($Hidden) {
		$item = Get-Item -LiteralPath $dir -Force
		$item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
	}
	return $dir
}

# A separate process, so the child's Set-StrictMode, exit code and $LASTEXITCODE
# are the real ones a developer sees rather than this script's.
function Invoke-FixtureScript {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Script,
		# Have the CHILD merge its own streams with 2>&1, the way a caller
		# piping the script's whole output would. Redirection at the process
		# level, as below, does not exercise that path at all.
		[switch] $MergeStreams
	)

	$outFile = Join-Path $FixtureRoot "out-$([System.Guid]::NewGuid().ToString('N')).log"
	$errFile = [System.IO.Path]::ChangeExtension($outFile, '.err.log')
	$scriptPath = Join-Path (Join-Path $RepoRoot 'scripts') $Script

	$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
	if ($MergeStreams) {
		$arguments += @('-Command', "`"& '$scriptPath' 2>&1 | Out-Null; exit `$LASTEXITCODE`"")
	}
	else {
		$arguments += @('-File', "`"$scriptPath`"")
	}

	$process = Start-Process -FilePath 'powershell.exe' `
		-ArgumentList $arguments `
		-WorkingDirectory $RepoRoot -NoNewWindow -Wait -PassThru `
		-RedirectStandardOutput $outFile -RedirectStandardError $errFile

	return [pscustomobject]@{
		ExitCode = $process.ExitCode
		Output   = Read-FixtureOutput -Files @($outFile, $errFile)
	}
}

function Read-FixtureOutput {
	param([Parameter(Mandatory)] [string[]] $Files)

	$text = ''
	foreach ($file in $Files) {
		if (Test-Path -LiteralPath $file) {
			$text += (Get-Content -LiteralPath $file -Raw)
			Remove-Item -LiteralPath $file -Force
		}
	}
	return $text
}

# Several runs of the same script started TOGETHER in one checkout -- what a
# developer produces by running the tests in two terminals, and the only shape
# in which the sweep's artefacts are shared. Started before any is waited on:
# run sequentially they never overlap and the case proves nothing.
function Invoke-FixtureScriptConcurrently {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Script,
		[Parameter(Mandatory)] [int] $Count
	)

	$scriptPath = Join-Path (Join-Path $RepoRoot 'scripts') $Script
	$started = @()
	for ($i = 0; $i -lt $Count; $i++) {
		$outFile = Join-Path $FixtureRoot "concurrent-$i-$([System.Guid]::NewGuid().ToString('N')).log"
		$errFile = [System.IO.Path]::ChangeExtension($outFile, '.err.log')
		$process = Start-Process -FilePath 'powershell.exe' `
			-ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") `
			-WorkingDirectory $RepoRoot -NoNewWindow -PassThru `
			-RedirectStandardOutput $outFile -RedirectStandardError $errFile

		# Touching .Handle makes the Process object cache the native handle.
		# Without -Wait it does not, and .ExitCode then reads back empty once
		# the child is gone -- which this case would report as a collision.
		$null = $process.Handle
		$started += [pscustomobject]@{ Process = $process; Out = $outFile; Err = $errFile }
	}

	$results = @()
	foreach ($run in $started) {
		$run.Process.WaitForExit()
		$results += [pscustomobject]@{
			ExitCode = $run.Process.ExitCode
			Output   = Read-FixtureOutput -Files @($run.Out, $run.Err)
		}
	}
	return $results
}

# -------------------------------------------------------------- assertions --

function Test-Case {
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [scriptblock] $Body
	)

	Write-Host ''
	Write-Host "--- $Name" -ForegroundColor Cyan
	try {
		& $Body
		Write-Host "    PASS" -ForegroundColor Green
		$script:Passes += 1
	}
	catch {
		if ([object]::ReferenceEquals($_.TargetObject, $SkipSignal)) {
			# A case whose SETUP this machine refused, which is not the same as
			# the case failing. Reported, never silent, and still checked
			# against $CasesAllowedToSkip in the summary.
			Write-Host "    SKIP: $($SkipSignal.Reason)" -ForegroundColor Yellow
			$script:Skips += [pscustomobject]@{ Name = $Name; Reason = $SkipSignal.Reason }
		}
		else {
			Write-Host "    FAIL: $($_.Exception.Message)" -ForegroundColor Red
			$script:Failures += "$Name -- $($_.Exception.Message)"
		}
	}
}

# A case this machine cannot set up. Distinct from a failure, and loud either
# way -- the summary lists skips even when everything else passes.
function Skip-Case {
	param([Parameter(Mandatory)] [string] $Reason)
	$SkipSignal.Reason = $Reason
	throw $SkipSignal
}

function Assert-ExitCode {
	param(
		[Parameter(Mandatory)] $Result,
		[Parameter(Mandatory)] [ValidateSet('zero', 'nonzero')] [string] $Expected
	)

	$isZero = ($Result.ExitCode -eq 0)
	if (($Expected -eq 'zero') -and (-not $isZero)) {
		throw "expected exit 0, got $($Result.ExitCode).`n$($Result.Output)"
	}
	if (($Expected -eq 'nonzero') -and $isZero) {
		throw "expected a non-zero exit, got 0.`n$($Result.Output)"
	}
}

function Assert-Output {
	param(
		[Parameter(Mandatory)] $Result,
		[Parameter(Mandatory)] [string] $Pattern
	)

	if ($Result.Output -notmatch $Pattern) {
		throw "output did not match /$Pattern/.`n$($Result.Output)"
	}
}

# ------------------------------------------------------------------- cases --

New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
Write-Host "Fixtures: $FixtureRoot"

Test-Case 'a single package with zero tests fails loudly' {
	$repo = New-FixtureRepo 'one-package'
	Add-FixturePackage -RepoRoot $repo -Name 'solo' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'no packages at all fails loudly' {
	$repo = New-FixtureRepo 'no-packages'
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'a repository path containing a space still runs its tests' {
	$repo = New-FixtureRepo 'path with space'
	Add-FixturePackage -RepoRoot $repo -Name 'spaced' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'zero'
	Assert-Output -Result $result -Pattern 'All 1 tests? passed'
}

Test-Case 'a package directory containing a space still runs its tests' {
	$repo = New-FixtureRepo 'spaced-package'
	# The directory carries the space, not the package identifier: `odin test`
	# re-parses the -out: path it builds on an unquoted command line, so a stem
	# named after this package exits -1 with "Unknown argument encountered
	# 'pkg.exe'" and the sweep runs nothing.
	Add-FixturePackage -RepoRoot $repo -Name 'spaced' -Directory 'my pkg' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'zero'
	Assert-Output -Result $result -Pattern 'All 1 tests? passed'
}

Test-Case 'two sweeps at once in one checkout do not collide' {
	$repo = New-FixtureRepo 'concurrent-sweeps'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'beta' -Test 'passing' | Out-Null
	# Artefact names fixed by package alone had each run deleting the report the
	# other was about to write, and the linker failing on an executable the
	# other still held: a spurious "collected ZERO tests" in an untouched tree.
	$results = @(Invoke-FixtureScriptConcurrently -RepoRoot $repo -Script 'test.ps1' -Count 2)
	foreach ($result in $results) {
		Assert-ExitCode -Result $result -Expected 'zero'
		Assert-Output -Result $result -Pattern 'All 2 tests? passed'
	}
}

Test-Case 'a passing sweep survives a caller that merges the output streams' {
	$repo = New-FixtureRepo 'merged-streams'
	Add-FixturePackage -RepoRoot $repo -Name 'merged' -Test 'passing' | Out-Null
	# `2>&1` in the caller makes PowerShell wrap the runner's stderr log in
	# ErrorRecords, and the sweep runs under $ErrorActionPreference = 'Stop':
	# without care the first INFO line of a good run terminates the script.
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' -MergeStreams
	Assert-ExitCode -Result $result -Expected 'zero'
	Assert-Output -Result $result -Pattern 'All 1 tests? passed'
}

Test-Case 'a hidden package is discovered, not skipped' {
	$repo = New-FixtureRepo 'hidden-package'
	Add-FixturePackage -RepoRoot $repo -Name 'visible' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'concealed' -Test 'failing' -Hidden | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'concealed'
}

Test-Case 'an unreadable directory fails discovery rather than shortening it' {
	$repo = New-FixtureRepo 'unreadable-directory'
	Add-FixturePackage -RepoRoot $repo -Name 'readable' -Test 'passing' | Out-Null
	$locked = Add-FixturePackage -RepoRoot $repo -Name 'locked' -Test 'failing'
	# Deny this account the right to list the directory. The account still owns
	# it, so the deny is removable again for cleanup without elevation.
	& icacls $locked /deny "${env:USERNAME}:(OI)(CI)(RD)" | Out-Null
	try {
		# A token holding SeBackupPrivilege walks straight past the deny. Prove
		# the setup took before asserting on it, rather than passing the case
		# for a reason that has nothing to do with the sweep.
		$denied = $false
		try {
			Get-ChildItem -LiteralPath $locked -Force -ErrorAction Stop | Out-Null
		}
		catch {
			$denied = $true
		}
		if (-not $denied) {
			Skip-Case -Reason 'this account can still list a directory it has been denied'
		}

		$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
		Assert-ExitCode -Result $result -Expected 'nonzero'
		Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
	}
	finally {
		& icacls $locked /remove:d "$env:USERNAME" | Out-Null
	}
}

Test-Case 'an undeclared package that collects zero tests fails the sweep' {
	$repo = New-FixtureRepo 'silent-package'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'beta' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'beta'
}

Test-Case 'a package declared test-less is allowed to have none' {
	$repo = New-FixtureRepo 'declared-testless'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'cli' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'zero'
}

Test-Case 'a package declared test-less that grows tests fails the sweep' {
	$repo = New-FixtureRepo 'stale-declaration'
	Add-FixturePackage -RepoRoot $repo -Name 'cli' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'cli'
}

Test-Case 'a deliberately failing test fails the sweep' {
	$repo = New-FixtureRepo 'failing-test'
	Add-FixturePackage -RepoRoot $repo -Name 'broken' -Test 'failing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'a test that leaks its returned slice fails rather than warns' {
	$repo = New-FixtureRepo 'leaking-test'
	Add-FixturePackage -RepoRoot $repo -Name 'leaky' -Test 'leaking' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
}

Test-Case 'a package that does not compile fails the sweep' {
	$repo = New-FixtureRepo 'broken-orphan'
	Add-FixturePackage -RepoRoot $repo -Name 'good' -Test 'passing' | Out-Null
	$orphan = Add-FixturePackage -RepoRoot $repo -Name 'orphan' -Test 'passing'
	[System.IO.File]::WriteAllText((Join-Path $orphan 'orphan.odin'), "package orphan`n`nthis is not Odin`n", $Utf8NoBom)
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'orphan'
}

# ----------------------------------------------------------------- summary --

if (Test-Path -LiteralPath $FixtureRoot) {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
}

Write-Host ''
Write-Host '========================================'

# The guard this file exists to be. A suite that ran fewer cases than it
# declares has not passed, however green every case it did run looks.
$attempted = $script:Passes + $script:Skips.Count + $script:Failures.Count
if ($attempted -ne $ExpectedCaseCount) {
	$script:Failures += "attempted $attempted case(s), but $ExpectedCaseCount are declared in `$ExpectedCaseCount"
}

if ($script:Skips.Count -gt 0) {
	Write-Host "Cases skipped: $($script:Skips.Count)" -ForegroundColor Yellow
	foreach ($skip in $script:Skips) {
		Write-Host "  - $($skip.Name) -- $($skip.Reason)" -ForegroundColor Yellow
		if ($CasesAllowedToSkip -notcontains $skip.Name) {
			$script:Failures += "$($skip.Name): skipped, and it is not named in `$CasesAllowedToSkip"
		}
	}
	Write-Host ''
}

if ($script:Failures.Count -gt 0) {
	Write-Host "SELFTEST FAILED in $($script:Failures.Count) case(s):" -ForegroundColor Red
	foreach ($failure in $script:Failures) {
		Write-Host "  - $failure" -ForegroundColor Red
	}
	Write-Host 'A test run that executes nothing is a failure, not a pass.' -ForegroundColor Red
	exit 1
}

Write-Host "All $script:Passes of $ExpectedCaseCount self-test cases passed." -ForegroundColor Green
exit 0
