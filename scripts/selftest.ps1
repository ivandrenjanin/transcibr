# Self-test for the build and test commands.
#
#   .\scripts\selftest.ps1
#
# The sweep in test.ps1 is the one script whose failure mode is silence: every
# bug it has shipped so far reported success having run nothing. Checking it by
# hand is exactly the discipline that let those bugs through, so the checks live
# here instead. build.ps1's checks -- the smoke test and the PE subsystem read
# -- fail loudly rather than silently, but they are checks nothing else checks,
# so they are covered here too.
#
# Each case plants a throwaway repository -- a copy of scripts\ next to a
# hand-built src\ -- runs the real script inside it as a separate process, and
# asserts on the exit code and the output. Nothing here touches the real src\.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-sourced for the declarations the fixtures have to agree with: the
# test-less package list a case plants a package into, and the target list a
# case builds. Spelled again here, they would go on passing while the real
# lists moved underneath them.
. (Join-Path $PSScriptRoot 'common.ps1')

$ScriptRoot = $PSScriptRoot
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "transcibr-selftest-$PID"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($OdinPackagesWithoutTests.Count -lt 1) {
	throw 'common.ps1 declares no test-less package, so two cases below have nothing to name.'
}
$DeclaredTestlessPackage = $OdinPackagesWithoutTests[0]

$SmokeTargets = @($OdinTargets | Where-Object { $_.Smoke })
if ($SmokeTargets.Count -lt 1) {
	throw 'common.ps1 declares no smoke-tested target, so the build cases have nothing to build.'
}
$SmokeTarget = $SmokeTargets[0]

$script:Failures = @()
$script:Skips = @()
$script:Passes = 0

# DECLARED, never counted from the cases that happened to run: a count taken
# from what ran cannot notice that nothing did. Keep it in step with the cases
# below -- a mismatch either way fails the run.
$ExpectedCaseCount = 33

# What the two cases that plant a package built to HANG give the sweep before
# they expect it to give up, and how long this suite then waits for any case.
#
# Far below $OdinCommandTimeoutSeconds, which is sized for a cold CI runner
# compiling from an empty cache: these fixtures are one file of five lines, whose
# slowest legitimate finish observed here is under ten seconds, and a suite that
# waited ten minutes to learn that a deliberate hang hung would not be run.
#
# $CaseTimeoutSeconds is EVERY case's bound and not just those two -- it is the
# default on the two procedures below that wait, so there is one number and not a
# named one beside an unnamed one that happened to be larger. It is the wider of
# the two on purpose: it is the backstop for the sweep failing to have a ceiling
# at all, so it must outlast the ceiling it is checking, which is what the guard
# below states.
$FixtureTimeoutSeconds = 20
$CaseTimeoutSeconds = 300

if ($CaseTimeoutSeconds -le $FixtureTimeoutSeconds) {
	throw "a case bound of $CaseTimeoutSeconds does not outlast the $FixtureTimeoutSeconds it hands the sweep, so every hang case would be killed by this suite instead of by the script it is checking."
}

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
	$scripts = Join-Path $root 'scripts'
	New-Item -ItemType Directory -Path $scripts -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
	Copy-Item -Path (Join-Path $ScriptRoot 'common.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'test.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'build.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'format.ps1') -Destination $scripts -Force
	# The style, copied rather than left out: build.ps1 checks formatting, and
	# common.ps1 resolves odinfmt.json from $RepoRoot -- which in here is the
	# fixture. Without it every build case fails on a missing config instead of
	# on the thing it checks.
	Copy-Item -Path (Join-Path $RepoRoot 'odinfmt.json') -Destination $root -Force
	return $root
}

# One fixture source file, written the way the real working tree holds one:
# UTF-8 with no BOM, tab-indented, and CRLF-terminated.
#
# CRLF is not cosmetic here. core.autocrlf is on, so every .odin file in a
# Windows checkout has CRLF endings, and odinfmt.json pins newline_style to
# match. A fixture written with bare LF is not a faithful copy of the repository
# it stands in for: it fails the formatting check on its line endings alone, and
# every build case would fail for a reason none of them is about.
function Write-FixtureSource {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
	)

	$crlf = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
	[System.IO.File]::WriteAllText($Path, $crlf, $Utf8NoBom)
}

# Odin source, written ASCII/no-BOM with tab indentation so the fixtures pass
# the same vet set as the real packages.
function Add-FixturePackage {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [ValidateSet('passing', 'failing', 'asserting', 'hanging', 'leaking', 'none')] [string] $Test,
		# The directory to plant the package in, where that has to differ from
		# the package name: an Odin identifier cannot contain a space and a
		# directory can, which is the whole point of the case that uses this.
		[string] $Directory = ''
	)

	if ($Directory -eq '') {
		$Directory = $Name
	}
	$dir = Join-Path (Join-Path $RepoRoot 'src') $Directory
	New-Item -ItemType Directory -Path $dir -Force | Out-Null

	# THREE asserting tests, not one. A single assertion fails cleanly every
	# time; it is two or more firing CONCURRENTLY that either crash the runner
	# with no summary or hang it forever (issue #22). The mechanism is written out
	# once, in CLAUDE.md's Odin notes.
	#
	# Joined rather than accumulated with a trailing blank line each: odinfmt
	# trims the blank line off the end of a file, so the accumulating form plants
	# a fixture that fails the formatting check on its last byte.
	$asserting = (@(1, 2, 3) | ForEach-Object {
			"@(test)`n${Name}_asserts_$_ :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n`tassert(false, `"deliberate assertion`")`n}`n"
		}) -join "`n"

	$body = switch ($Test) {
		'passing' { "import `"core:testing`"`n`n@(test)`n${Name}_passes :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n}`n" }
		'failing' { "import `"core:testing`"`n`n@(test)`n${Name}_fails :: proc(t: ^testing.T) {`n`ttesting.expect(t, false, `"deliberate failure`")`n}`n" }
		'asserting' { "import `"core:testing`"`n`n$asserting" }
		'hanging' { "import `"core:testing`"`nimport `"core:time`"`n`n@(test)`n${Name}_never_returns :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n`tfor {`n`t`ttime.sleep(time.Second)`n`t}`n}`n" }
		'leaking' { "import `"core:testing`"`n`n@(test)`n${Name}_leaks :: proc(t: ^testing.T) {`n`tleaked := make([]u8, 8, context.allocator)`n`ttesting.expect(t, len(leaked) == 8)`n}`n" }
		'none' { "${Name}_CONSTANT :: 1`n" }
	}
	$source = "package $Name`n`n$body"
	Write-FixtureSource -Path (Join-Path $dir "$Name.odin") -Text $source
	return $dir
}

# The package build.ps1 will find at $SmokeTarget.Package, so the build cases
# drive the real target list rather than a name spelled again here.
function Add-FixtureBinary {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Body
	)

	$dir = Join-Path (Join-Path $RepoRoot 'src') $SmokeTarget.Package
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'main.odin') -Text "package main`n`n$Body"
	return $dir
}

# A built executable that prints the argv it received, one bracketed argument per
# line. Ground truth for the quoter and for nothing else, which is why it is not
# built through build.ps1: that command smoke-tests what it builds against the
# version banner, and this program has no version to report.
function Build-FixtureArgvDumper {
	param([Parameter(Mandatory)] [string] $RepoRoot)

	$dir = Join-Path (Join-Path $RepoRoot 'src') 'argv'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	$source = "package main`n`nimport `"core:fmt`"`nimport `"core:os`"`n`nmain :: proc() {`n`tfor argument in os.args[1:] {`n`t`tfmt.printfln(`"[%s]`", argument)`n`t}`n}`n"
	Write-FixtureSource -Path (Join-Path $dir 'argv.odin') -Text $source

	$exe = Join-Path $RepoRoot 'argv.exe'
	$built = Invoke-NativeCommand -Command (Resolve-OdinCompiler) -TimeoutSeconds $FixtureTimeoutSeconds `
		-Arguments (@('build', $dir, "-out:$exe") + $OdinVetFlags)
	if ($built.TimedOut) {
		throw "building the argv dumper did not finish within $FixtureTimeoutSeconds seconds."
	}
	if ($built.ExitCode -ne 0) {
		throw "building the argv dumper exited $($built.ExitCode)."
	}
	return $exe
}

# A binary that prints one line and exits zero, the shape build.ps1's smoke
# test is looking for. $Line and $Exit are what each case varies.
function New-FixtureMain {
	param(
		[Parameter(Mandatory)] [AllowEmptyString()] [string] $Line,
		[int] $Exit = 0
	)

	# The import list is emitted from what the body uses, because -vet rejects an
	# unused import: the silent binary carries no core:fmt, and one exiting zero
	# -- which main does by returning -- carries no core:os. Keeping a call in
	# the body to keep an import used reads as a bug in the fixture rather than
	# as the case it stands for.
	$imports = @()
	$body = ''
	if ($Line -ne '') {
		$imports += 'import "core:fmt"'
		$body += "`tfmt.println(`"$Line`")`n"
	}
	if ($Exit -ne 0) {
		$imports += 'import "core:os"'
		$body += "`tos.exit($Exit)`n"
	}

	$head = ''
	if ($imports.Count -gt 0) {
		$head = ($imports -join "`n") + "`n`n"
	}
	return $head + "main :: proc() {`n$body}`n"
}

# A separate process, so the child's Set-StrictMode, exit code and $LASTEXITCODE
# are the real ones a developer sees rather than this script's.
#
# Started but NOT waited on, because one case needs several runs of the same
# script in flight together -- run one after another they never overlap and that
# case proves nothing. Every caller pairs this with Wait-FixtureScript.
function Start-FixtureScript {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Script,
		# Passed on to the script itself, e.g. -TestName. Deliberately not named
		# $Arguments: PowerShell matches variable names case-insensitively, so
		# that name and the local $arguments below are ONE variable, and the
		# host's own flags end up passed to the script under test.
		[string[]] $ScriptArguments = @(),
		# Have the CHILD merge its own streams with 2>&1, the way a caller
		# piping the script's whole output would. Redirecting at the process
		# level, as below, does not exercise that path at all.
		[switch] $MergeStreams
	)

	$outFile = Join-Path $FixtureRoot "out-$([System.Guid]::NewGuid().ToString('N')).log"
	$errFile = [System.IO.Path]::ChangeExtension($outFile, '.err.log')
	$scriptPath = Join-Path (Join-Path $RepoRoot 'scripts') $Script

	$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
	if ($MergeStreams) {
		if ($ScriptArguments.Count -gt 0) {
			throw 'Start-FixtureScript cannot pass -ScriptArguments through -MergeStreams.'
		}
		$arguments += @('-Command', "`"& '$scriptPath' 2>&1 | Out-Null; exit `$LASTEXITCODE`"")
	}
	else {
		$arguments += @('-File', "`"$scriptPath`"") + $ScriptArguments
	}

	$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
		-WorkingDirectory $RepoRoot -NoNewWindow -PassThru `
		-RedirectStandardOutput $outFile -RedirectStandardError $errFile

	# Touching .Handle makes the Process object cache the native handle. Without
	# -Wait it does not, and .ExitCode then reads back empty once the child is
	# gone -- which the concurrency case would report as a collision. It has to
	# happen HERE, at the start site, the same way Start-NativeProcess does it:
	# measured, asking for it after the child has exited does not work.
	$null = $process.Handle
	return [pscustomobject]@{ Process = $process; Out = $outFile; Err = $errFile }
}

# What the run exited with and everything it printed, both streams in one string.
#
# Bounded, and every case gets the bound: this suite's whole job is to check
# the scripts fail LOUDLY, and a suite that waits forever for one of them cannot
# report anything at all. The bound is the suite's own backstop and not the
# thing under test -- $TimedOut is a FAILURE wherever Assert-Result reads it, so
# a case that hits it says the script under test has no ceiling of its own.
#
# The wait, the tree kill and the re-wait are Wait-ProcessTree in common.ps1,
# which this file dot-sources: the script under test spawns odin.exe, which
# spawns the test binary, and it is the innermost one that hangs -- the same
# thing common.ps1 says about the same three processes.
function Wait-FixtureScript {
	param(
		[Parameter(Mandatory)] $Run,
		[ValidateRange(1, 86400)] [int] $TimeoutSeconds = $script:CaseTimeoutSeconds
	)

	$waited = Wait-ProcessTree -Process $Run.Process -TimeoutSeconds $TimeoutSeconds

	$text = ''
	foreach ($file in @($Run.Out, $Run.Err)) {
		if (Test-Path -LiteralPath $file) {
			$text += (Get-Content -LiteralPath $file -Raw)
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}
	return [pscustomobject]@{
		ExitCode = $waited.ExitCode
		Output   = $text
		TimedOut = $waited.TimedOut
		Waited   = $TimeoutSeconds
	}
}

# The shape every case but one wants: start it, wait for it, read it.
function Invoke-FixtureScript {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Script,
		[string[]] $ScriptArguments = @(),
		[ValidateRange(1, 86400)] [int] $TimeoutSeconds = $script:CaseTimeoutSeconds,
		[switch] $MergeStreams
	)

	return Wait-FixtureScript -TimeoutSeconds $TimeoutSeconds -Run (Start-FixtureScript -RepoRoot $RepoRoot `
			-Script $Script -ScriptArguments $ScriptArguments -MergeStreams:$MergeStreams)
}

# -------------------------------------------------------------- assertions --

function Test-Case {
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [scriptblock] $Body,
		# Deny-by-default, the policy $OdinPackagesWithoutTests keeps in
		# common.ps1: Skip-Case is a FAILURE unless the case carries this. It is
		# carried by the case rather than by a list of names, because a list
		# keyed on a case's display string drops its allowance on a rename --
		# turning renaming a case into a failed run, for no other reason.
		[switch] $MaySkip
	)

	Write-Host ''
	Write-Host "--- $Name" -ForegroundColor Cyan
	try {
		& $Body
		Write-Host "    PASS" -ForegroundColor Green
		$script:Passes += 1
	}
	catch {
		if (-not [object]::ReferenceEquals($_.TargetObject, $SkipSignal)) {
			Write-Host "    FAIL: $($_.Exception.Message)" -ForegroundColor Red
			$script:Failures += "$Name -- $($_.Exception.Message)"
		}
		elseif (-not $MaySkip) {
			$why = "skipped, and it does not carry -MaySkip: $($SkipSignal.Reason)"
			Write-Host "    FAIL: $why" -ForegroundColor Red
			$script:Failures += "$Name -- $why"
		}
		else {
			# A case whose SETUP this machine refused, which is not the same as
			# the case failing. Reported, never silent: the summary lists skips
			# even when everything else passes.
			Write-Host "    SKIP: $($SkipSignal.Reason)" -ForegroundColor Yellow
			$script:Skips += [pscustomobject]@{ Name = $Name; Reason = $SkipSignal.Reason }
		}
	}
}

# A case this machine cannot set up, from inside the case's own body.
function Skip-Case {
	param([Parameter(Mandatory)] [string] $Reason)
	$SkipSignal.Reason = $Reason
	throw $SkipSignal
}

# What a case has to say about a run: whether it should have failed, and what
# its output should have named. Never one without the other in practice -- an
# exit code alone does not say the script failed for the reason under test --
# so they are one assertion with the pattern optional.
function Assert-Result {
	param(
		[Parameter(Mandatory)] $Result,
		[switch] $Fails,
		[string] $Matching = ''
	)

	# Read before the exit code, because a run this suite had to kill has no
	# verdict to read: the -1 it carries would otherwise pass -Fails and report
	# a script that hangs forever as a script that failed loudly.
	if ($Result.TimedOut) {
		throw "the run did not finish within $($Result.Waited) seconds and was killed.`n$($Result.Output)"
	}

	$isZero = ($Result.ExitCode -eq 0)
	if ($Fails -and $isZero) {
		throw "expected a non-zero exit, got 0.`n$($Result.Output)"
	}
	if ((-not $Fails) -and (-not $isZero)) {
		throw "expected exit 0, got $($Result.ExitCode).`n$($Result.Output)"
	}
	if (($Matching -ne '') -and ($Result.Output -notmatch $Matching)) {
		throw "output did not match /$Matching/.`n$($Result.Output)"
	}
}

# The <package>.<test> names a document hands a reader to run, in every spelling
# PowerShell itself binds: a space or a colon before the value, the value quoted
# either way, and any casing -- [regex]::Matches is case-SENSITIVE, so `-testname`
# read as no command at all. The dot is what keeps prose about the flag
# ("-TestName takes <package>.<test>") from reading as a name.
function Get-DocumentedTestName {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$matched = [regex]::Matches($Text, '(?i)-TestName[:\s]+["'']?([A-Za-z0-9_]+\.[A-Za-z0-9_]+)')
	return @($matched | ForEach-Object { $_.Groups[1].Value })
}

# ------------------------------------------------------------------- cases --

New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
Write-Host "Fixtures: $FixtureRoot"

Test-Case 'a single package with zero tests fails loudly' {
	$repo = New-FixtureRepo 'one-package'
	Add-FixturePackage -RepoRoot $repo -Name 'solo' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching 'TEST COMMAND FAILED'
}

Test-Case 'no packages at all fails loudly' {
	$repo = New-FixtureRepo 'no-packages'
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching 'TEST COMMAND FAILED'
}

Test-Case 'a repository path containing a space still runs its tests' {
	$repo = New-FixtureRepo 'path with space'
	Add-FixturePackage -RepoRoot $repo -Name 'spaced' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Matching 'All 1 tests? passed'
}

Test-Case 'a package directory containing a space still runs its tests' {
	$repo = New-FixtureRepo 'spaced-package'
	# The directory carries the space, not the package identifier: `odin test`
	# re-parses the -out: path it builds on an unquoted command line, so a stem
	# named after this package exits -1 with "Unknown argument encountered
	# 'pkg.exe'" and the sweep runs nothing.
	Add-FixturePackage -RepoRoot $repo -Name 'spaced' -Directory 'my pkg' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Matching 'All 1 tests? passed'
}

# Both scripts hand user-controlled strings to a native command line, and Windows
# has no array form of one: CreateProcessW takes a single string, so every
# argument is escaped by ConvertTo-NativeArgument and un-escaped by
# CommandLineToArgvW inside the child. The two space-in-a-path cases above check
# that indirectly, through whether the sweep works at all. This checks it
# directly, against the only ground truth there is -- a program printing the argv
# it actually received.
Test-Case 'every argument survives the trip through a native command line' {
	$repo = New-FixtureRepo 'argv-round-trip'
	$dumper = Build-FixtureArgvDumper -RepoRoot $repo

	# The empty string is first because it is the one PowerShell's own native
	# argument passing drops outright, and a dropped argument shifts every
	# argument after it by one.
	$sent = @(
		''
		'plain'
		'two words'
		'C:\path with space\'
		'a"quoted"b'
		'trailing\\'
		'-define:NAME=a b"c'
	)
	$read = Read-NativeOutput -Command $dumper -Arguments $sent -TimeoutSeconds $FixtureTimeoutSeconds
	if ($read.TimedOut) {
		throw "the argv dumper did not finish within $FixtureTimeoutSeconds seconds."
	}
	if ($read.ExitCode -ne 0) {
		throw "the argv dumper exited $($read.ExitCode).`n$($read.Output)"
	}

	$received = @($read.Output -split "`r?`n")
	if ($received.Count -ne $sent.Count) {
		throw "sent $($sent.Count) arguments, the child received $($received.Count).`n$($read.Output)"
	}
	for ($i = 0; $i -lt $sent.Count; $i++) {
		if ($received[$i] -ne "[$($sent[$i])]") {
			throw "argument $i arrived as $($received[$i]), sent [$($sent[$i])]."
		}
	}
}

Test-Case 'two sweeps at once in one checkout do not collide' {
	$repo = New-FixtureRepo 'concurrent-sweeps'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'beta' -Test 'passing' | Out-Null
	# Artefact names fixed by package alone had each run deleting the report the
	# other was about to write, and the linker failing on an executable the
	# other still held: a spurious "collected ZERO tests" in an untouched tree.
	#
	# Both started before either is waited on -- that is the whole case. Waiting
	# on the first before starting the second is two sequential runs.
	$runs = @(1, 2 | ForEach-Object { Start-FixtureScript -RepoRoot $repo -Script 'test.ps1' })
	foreach ($run in $runs) {
		Assert-Result -Result (Wait-FixtureScript -Run $run) -Matching 'All 2 tests? passed'
	}
}

Test-Case 'a passing sweep survives a caller that merges the output streams' {
	$repo = New-FixtureRepo 'merged-streams'
	Add-FixturePackage -RepoRoot $repo -Name 'merged' -Test 'passing' | Out-Null
	# `2>&1` in the caller makes PowerShell wrap the runner's stderr log in
	# ErrorRecords, and the sweep runs under $ErrorActionPreference = 'Stop':
	# without care the first INFO line of a good run terminates the script.
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' -MergeStreams
	Assert-Result -Result $result -Matching 'All 1 tests? passed'
}

Test-Case 'a hidden package is discovered, not skipped' {
	$repo = New-FixtureRepo 'hidden-package'
	Add-FixturePackage -RepoRoot $repo -Name 'visible' -Test 'passing' | Out-Null
	$concealed = Add-FixturePackage -RepoRoot $repo -Name 'concealed' -Test 'failing'
	$item = Get-Item -LiteralPath $concealed -Force
	$item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching 'concealed'
}

# The one case that may skip: a token holding SeBackupPrivilege walks straight
# past the deny it plants, so that machine cannot set it up.
Test-Case 'an unreadable directory fails discovery rather than shortening it' -MaySkip {
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
		Assert-Result -Result $result -Fails -Matching 'TEST COMMAND FAILED'
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
	Assert-Result -Result $result -Fails -Matching 'beta'
}

Test-Case 'a package declared test-less is allowed to have none' {
	$repo = New-FixtureRepo 'declared-testless'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name $DeclaredTestlessPackage -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result
}

Test-Case 'a package declared test-less that grows tests fails the sweep' {
	$repo = New-FixtureRepo 'stale-declaration'
	Add-FixturePackage -RepoRoot $repo -Name $DeclaredTestlessPackage -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching $DeclaredTestlessPackage
}

# EXPECTATION failures only, and that is the whole of what it covers. A failed
# testing.expect is recorded and returned from normally, so the runner reaches
# its summary and exits non-zero on its own -- which is the easy half. The two
# cases below cover the half this one cannot reach: an ASSERTION, which does not
# return from anywhere.
Test-Case 'a test that fails an expectation fails the sweep' {
	$repo = New-FixtureRepo 'failing-test'
	Add-FixturePackage -RepoRoot $repo -Name 'broken' -Test 'failing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching 'TEST COMMAND FAILED'
}

# The case above's missing half, and the reason issue #22 exists. Three tests
# assert CONCURRENTLY, which is the shape that breaks the runner.
#
# What is pinned is the outcome and not the mechanism, deliberately. Whichever
# of the three the runner does on the day -- hang, crash, or the rare clean exit
# 1 -- the sweep must come back non-zero, and it must come back. The sweep's own
# ceiling is what closes the hang; the crash path it already caught.
Test-Case 'tests that assert concurrently fail the sweep in bounded time' {
	$repo = New-FixtureRepo 'asserting-tests'
	Add-FixturePackage -RepoRoot $repo -Name 'tripwire' -Test 'asserting' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' `
		-ScriptArguments @('-TimeoutSeconds', "$FixtureTimeoutSeconds")
	Assert-Result -Result $result -Fails -Matching 'TEST COMMAND FAILED'
}

# The ceiling itself, exercised deterministically. The case above is the real
# defect and the runner decides how it manifests; this one plants a test that
# simply never returns, so there is exactly one way for the sweep to survive it.
#
# Naming the package is the point, not a nicety: a killed run writes no JSON
# report, so every other signal the sweep reads is missing, and "something timed
# out" over a sweep of every package under src\ is not a report anyone can act
# on.
Test-Case 'a test that never returns is killed and reported against its package' {
	$repo = New-FixtureRepo 'hanging-test'
	Add-FixturePackage -RepoRoot $repo -Name 'wedged' -Test 'hanging' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' `
		-ScriptArguments @('-TimeoutSeconds', "$FixtureTimeoutSeconds")
	Assert-Result -Result $result -Fails -Matching 'wedged'
	Assert-Result -Result $result -Fails -Matching "did not finish within $FixtureTimeoutSeconds"
}

# The ceilings against each other and against the job they have to report from.
#
# Three numbers in two files, and the relationship between them is the whole
# point: one package's ceiling times however many packages exist is not a bound
# anybody chose, and a sweep bound at or past the CI job's own timeout is a hang
# reported by GitHub -- which names no package, prints no output, and uploads no
# report -- rather than by the sweep. Checked rather than written down, because
# the fourth package is exactly when nobody re-reads the comment.
Test-Case 'the sweep budget fits inside the CI job that has to report it' {
	$workflow = Join-Path $RepoRoot '.github\workflows\ci.yml'
	if (-not (Test-Path -LiteralPath $workflow)) {
		throw "no $workflow to read the job timeout out of."
	}
	$declared = [regex]::Match((Get-Content -LiteralPath $workflow -Raw), '(?m)^\s*timeout-minutes:\s*(\d+)')
	if (-not $declared.Success) {
		throw "no timeout-minutes in $workflow, so the job falls back to the platform's six-hour default."
	}

	$job = [int] $declared.Groups[1].Value * 60
	if ($OdinSweepTimeoutSeconds -lt $OdinCommandTimeoutSeconds) {
		throw "the sweep's $OdinSweepTimeoutSeconds-second budget is below one package's $OdinCommandTimeoutSeconds, so a single slow package is killed by the sweep rather than by its own ceiling."
	}
	if ($OdinSweepTimeoutSeconds -ge $job) {
		throw "the sweep's $OdinSweepTimeoutSeconds-second budget reaches the CI job's own $job, so a hang is reported by the job timeout, which names nothing, rather than by the sweep naming the package."
	}
}

Test-Case 'a test that leaks its returned slice fails rather than warns' {
	$repo = New-FixtureRepo 'leaking-test'
	Add-FixturePackage -RepoRoot $repo -Name 'leaky' -Test 'leaking' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails
}

Test-Case 'every single-test command in the documentation runs the test it names' {
	# A test's name written into prose is the one copy no compiler checks, and
	# it went stale the first time a test was renamed. The names are DISCOVERED
	# from the documents rather than listed here: a guard holding its own copy
	# of what it guards is the same hand-maintained duplicate it exists to catch.
	#
	# Per document, never pooled across the three. A pooled count is satisfied by
	# whichever document still matches, so rewording ONE of them into a form the
	# pattern misses leaves it free to print a stale name indefinitely.
	$documented = @()
	foreach ($document in @((Join-Path $RepoRoot 'CLAUDE.md'), (Join-Path $RepoRoot 'README.md'), (Join-Path $ScriptRoot 'test.ps1'))) {
		if (-not (Test-Path -LiteralPath $document)) {
			throw "no $document to read the documented commands out of."
		}
		$found = @(Get-DocumentedTestName -Text (Get-Content -LiteralPath $document -Raw))
		if ($found.Count -eq 0) {
			throw "no -TestName example found in $document, so nothing checks the name it prints."
		}
		$documented += $found
	}

	$documented = @($documented | Sort-Object -Unique)

	# Run against the REAL repository, which is the whole claim a document that
	# prints a command makes: that running it here does what it says.
	foreach ($name in $documented) {
		$result = Invoke-FixtureScript -RepoRoot $RepoRoot -Script 'test.ps1' -ScriptArguments @('-TestName', $name)
		Assert-Result -Result $result -Matching 'All 1 tests? passed'
	}

	# The negative space (CLAUDE.md rule A3). Without it the loop above passes
	# for any string at all the moment -TestName stops failing on a bad name.
	$absent = Invoke-FixtureScript -RepoRoot $RepoRoot -Script 'test.ps1' `
		-ScriptArguments @('-TestName', "$($documented[0])_no_such_test")
	Assert-Result -Result $absent -Fails -Matching 'no test named'
}

Test-Case 'the documented-command reader accepts every spelling of the flag' {
	# The guard above is worth exactly what this pattern reads. A spelling it
	# misses is a document that quietly stops being checked -- and the check
	# above cannot notice, because a document with no commands in it looks the
	# same as a document whose commands were not recognised.
	$spellings = @(
		'.\scripts\test.ps1 -TestName version.some_test'
		'.\scripts\test.ps1 -TestName:version.some_test'
		".\scripts\test.ps1 -TestName 'version.some_test'"
		'.\scripts\test.ps1 -TestName "version.some_test"'
		'.\scripts\test.ps1 -testname version.some_test'
	)
	foreach ($spelling in $spellings) {
		if (@(Get-DocumentedTestName -Text $spelling) -notcontains 'version.some_test') {
			throw "read no test name out of: $spelling"
		}
	}

	# The negative space (rule A3): prose ABOUT the flag names no test, and a
	# pattern loose enough to read it as one sends the guard chasing <package>.
	$prose = @(Get-DocumentedTestName -Text '-TestName takes <package>.<test>.')
	if ($prose.Count -ne 0) {
		throw "read '$($prose -join "', '")' out of prose about the flag."
	}
}

Test-Case 'a package that does not compile fails the sweep' {
	$repo = New-FixtureRepo 'broken-orphan'
	Add-FixturePackage -RepoRoot $repo -Name 'good' -Test 'passing' | Out-Null
	$orphan = Add-FixturePackage -RepoRoot $repo -Name 'orphan' -Test 'passing'
	Write-FixtureSource -Path (Join-Path $orphan 'orphan.odin') -Text "package orphan`n`nthis is not Odin`n"
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-Result -Result $result -Fails -Matching 'orphan'
}

Test-Case 'an artefact left behind by an earlier run is reclaimed, a fresh one is not' {
	# test.ps1 names every artefact for the run that wrote it and deletes its
	# own on the way out, so nothing will ever name the files a KILLED run left
	# -- or the files an older naming scheme wrote. Under build\ that is merely
	# untidy; under the ProgramData fallback it is a machine-wide directory that
	# only grows, and no one ever looks in it.
	$root = Get-OdinTestRoot
	$stale = Join-Path $root "selftest-stale-$PID.json"
	$fresh = Join-Path $root "selftest-fresh-$PID.json"
	try {
		[System.IO.File]::WriteAllText($stale, '{}', $Utf8NoBom)
		[System.IO.File]::WriteAllText($fresh, '{}', $Utf8NoBom)
		(Get-Item -LiteralPath $stale -Force).LastWriteTime = (Get-Date).AddDays(-30)

		Get-OdinTestRoot | Out-Null

		if (Test-Path -LiteralPath $stale) {
			throw "a 30-day-old artefact survived the sweep: $stale"
		}
		# The negative space (rule A3), and not a formality: a sweep with no age
		# bound at all passes the check above and destroys the executable a
		# concurrent run is at that moment trying to launch.
		if (-not (Test-Path -LiteralPath $fresh)) {
			throw "an artefact written moments ago was reclaimed: $fresh"
		}
	}
	finally {
		Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
		Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
	}
}

# ------------------------------------------------------- cases for build.ps1 --
#
# The build's own checks -- that the binary starts, reports a version, exits
# zero, and carries the subsystem it was built for -- are the acceptance
# criteria of this repository's first ticket, and until now nothing but a
# careful reader guarded them.

Test-Case 'the build command builds, smoke-tests and reports its target' {
	$repo = New-FixtureRepo 'build-happy'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line "$($SmokeTarget.Name) 0.1.0") | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Matching "printed: $([regex]::Escape($SmokeTarget.Name)) 0\.1\.0"
}

Test-Case 'a binary that prints nothing fails the build' {
	$repo = New-FixtureRepo 'build-silent'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line '') | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'did not report a version'
}

Test-Case 'a binary that prints the wrong text fails the build' {
	$repo = New-FixtureRepo 'build-wrong-text'
	# Right shape, wrong program: a binary reporting someone else's name is the
	# failure a check for "printed something" would wave through.
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line 'some-other-program 0.1.0') | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'did not report a version'
}

Test-Case 'a binary that exits non-zero fails the build' {
	$repo = New-FixtureRepo 'build-bad-exit'
	# Prints exactly what is wanted and then fails, so it is the exit code and
	# nothing else that this case turns on.
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line "$($SmokeTarget.Name) 0.1.0" -Exit 3) | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'exited 3, expected 0'
}

Test-Case 'the subsystem is read out of the PE header, not taken from the flag' {
	# Ground truth Windows ships: cmd.exe is a console image and explorer.exe is
	# a GUI one. Checked against those rather than against a binary this suite
	# built with the same flag it then asserts on, which would agree with itself
	# whatever the reader did.
	$console = Join-Path $env:SystemRoot 'System32\cmd.exe'
	$gui = Join-Path $env:SystemRoot 'explorer.exe'
	foreach ($path in @($console, $gui)) {
		if (-not (Test-Path -LiteralPath $path)) {
			# A failure rather than a skip. Both images ship with every Windows
			# install this repository targets, so their absence is a broken
			# machine and not a case this run may quietly decline to make.
			throw "no $path on this machine to check the PE reader against."
		}
	}

	Assert-PeSubsystem -Path $console -Subsystem 'console'
	Assert-PeSubsystem -Path $gui -Subsystem 'windows'

	# And the negative space (rule A3): a reader that never rejects anything
	# agrees with both lines above. An empty message is the "nothing was thrown"
	# case, which -notmatch catches along with the wrong message.
	$mismatched = ''
	try { Assert-PeSubsystem -Path $gui -Subsystem 'console' } catch { $mismatched = $_.Exception.Message }
	if ($mismatched -notmatch 'is subsystem 2, expected 3') {
		throw "reading a GUI image as console gave: '$mismatched'"
	}
	$notAnImage = ''
	try { Assert-PeSubsystem -Path (Join-Path $ScriptRoot 'common.ps1') -Subsystem 'console' } catch { $notAnImage = $_.Exception.Message }
	if ($notAnImage -notmatch 'does not start with the MZ signature') {
		throw "reading a script as a PE image gave: '$notAnImage'"
	}
}

# ------------------------------------------------------ cases for format.ps1 --
#
# CLAUDE.md rule S1's formatter, which until now nothing ran at all. The check
# it drives has the same failure mode the test sweep has -- silence -- so it is
# guarded the same way: every case below is about the check REFUSING something,
# and the two that are about it accepting exist so the refusals cannot be
# satisfied by a check that refuses everything.
#
# The fixtures misformat by IMPORT ORDER. It is valid Odin, it passes the whole
# vet set, so a case that fails is failing on FORMATTING and not on something
# the compiler would have caught anyway -- and the misformatted and formatted
# forms are the same LENGTH, so a check comparing file sizes rather than
# contents would wave every one of them through.
#
# Otherwise the binary New-FixtureMain builds: it still prints the banner and
# still exits zero, so build.ps1's smoke test passes once the imports are put
# back in order. That is what makes the -Fix case able to build what it rewrote.
function New-FixtureMainUnsorted {
	param([Parameter(Mandatory)] [string] $Line)

	return "import `"core:os`"`nimport `"core:fmt`"`n`nmain :: proc() {`n`tfmt.println(`"$Line`")`n`tos.exit(0)`n}`n"
}

$SmokeBanner = "$($SmokeTarget.Name) 0.1.0"

Test-Case 'a misformatted file fails the build' {
	$repo = New-FixtureRepo 'build-misformatted'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMainUnsorted -Line $SmokeBanner) | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'not formatted as odinfmt.json says'
	Assert-Result -Result $result -Fails -Matching 'main\.odin'
}

Test-Case 'the format command passes a formatted file and fails a misformatted one' {
	# Both halves, because either alone proves nothing: a check that accepts
	# everything passes the first, and one that accepts nothing passes the second
	# (CLAUDE.md rule A3).
	$clean = New-FixtureRepo 'format-clean'
	Add-FixtureBinary -RepoRoot $clean -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $clean -Script 'format.ps1') -Matching 'are formatted as odinfmt.json says'

	$dirty = New-FixtureRepo 'format-dirty'
	Add-FixtureBinary -RepoRoot $dirty -Body (New-FixtureMainUnsorted -Line $SmokeBanner) | Out-Null
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $dirty -Script 'format.ps1') -Fails -Matching 'main\.odin'
}

Test-Case 'the format check covers Odin outside src' {
	# The sweep walks $RepoRoot and not $SrcRoot on purpose: docs\reference\ holds
	# a spike that is still Odin somebody reads and copies from, and a check
	# scoped to src\ would leave it drifting. Discovered rather than listed, so
	# this file is covered by having been WRITTEN and not by being named anywhere.
	$repo = New-FixtureRepo 'format-outside-src'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$spike = Join-Path $repo 'docs\reference'
	New-Item -ItemType Directory -Path $spike -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $spike 'spike.odin') `
		-Text "package reference`n`nimport `"core:os`"`nimport `"core:fmt`"`n`nspike :: proc() {`n`tfmt.println(os.args[0])`n}`n"

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1'
	Assert-Result -Result $result -Fails -Matching 'docs/reference/spike\.odin'
}

Test-Case 'a repository with no Odin at all fails the format command' {
	# The deny-by-default rule, in the one place it matters most. A formatting
	# check that discovers nothing reports exactly the green a check that
	# discovered everything reports, and no one can tell the two apart.
	$repo = New-FixtureRepo 'format-no-sources'
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1'
	Assert-Result -Result $result -Fails -Matching 'no \.odin files found'
}

Test-Case 'a source with LF line endings fails the format check' {
	# Deliberate, and recorded here rather than left to be discovered: the check
	# IS line-ending-sensitive. core.autocrlf is on, so a Windows checkout holds
	# CRLF, odinfmt.json pins newline_style to CRLF to match, and odinfmt's own
	# default would have been LF had this run anywhere but Windows.
	$repo = New-FixtureRepo 'format-lf-endings'
	$dir = Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner)
	$main = Join-Path $dir 'main.odin'
	# Only the line endings differ from the file that just passed; nothing else
	# about the fixture changes.
	$lf = [System.IO.File]::ReadAllText($main) -replace "`r`n", "`n"
	[System.IO.File]::WriteAllText($main, $lf, $Utf8NoBom)

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1'
	Assert-Result -Result $result -Fails -Matching 'main\.odin'
}

Test-Case 'a config odinfmt would silently ignore fails the format command' {
	# odinfmt's find_config_file_or_default returns its own built-in default
	# whenever the file is missing or json.unmarshal fails, and says NOTHING. A
	# trailing comma in odinfmt.json would otherwise leave every command here
	# passing against a style nobody chose -- and that default is
	# platform-dependent, so it would not even be the same style twice.
	$missing = New-FixtureRepo 'format-config-missing'
	Add-FixtureBinary -RepoRoot $missing -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Remove-Item -LiteralPath (Join-Path $missing 'odinfmt.json') -Force
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $missing -Script 'format.ps1') -Fails -Matching 'no .*odinfmt\.json'

	$broken = New-FixtureRepo 'format-config-broken'
	Add-FixtureBinary -RepoRoot $broken -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $broken 'odinfmt.json'), '{ "character_width": 100, oops }', $Utf8NoBom)
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $broken -Script 'format.ps1') -Fails -Matching 'not valid JSON'
}

Test-Case 'the format command rewrites exactly what it named' {
	$repo = New-FixtureRepo 'format-fix'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMainUnsorted -Line $SmokeBanner) | Out-Null
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1') -Fails

	$fixed = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1' -ScriptArguments @('-Fix')
	Assert-Result -Result $fixed -Matching 'rewrote'

	# The check after the fix, which is the only thing that makes -Fix worth
	# having: a rewrite the check still rejects is a rewrite to a third style.
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1') -Matching 'are formatted as odinfmt.json says'

	# And it still compiles -- a formatter that produces something the vet set
	# rejects has fixed nothing.
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1')
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
