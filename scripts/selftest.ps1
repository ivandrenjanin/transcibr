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
$ExpectedCaseCount = 50

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
		[switch] $MergeStreams,

		# Environment the child is to see, as name -> value. Start-Process has no
		# way to pass one, so these are set on THIS process across the start and
		# put back afterwards -- the child inherits at CreateProcess time, so the
		# window is the one call. An empty value UNSETS the variable, which is how
		# a case asks for a child that is not running under CI: PowerShell deletes
		# an environment variable assigned the empty string, and the whole suite
		# runs with $env:CI set when CI is the thing running it.
		[hashtable] $Environment = @{}
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

	$restore = @{}
	foreach ($name in $Environment.Keys) {
		$restore[$name] = [System.Environment]::GetEnvironmentVariable($name)
		Set-Item -LiteralPath "env:$name" -Value $Environment[$name]
	}
	try {
		$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
			-WorkingDirectory $RepoRoot -NoNewWindow -PassThru `
			-RedirectStandardOutput $outFile -RedirectStandardError $errFile
	}
	finally {
		# Put back whatever was there, including nothing. A leaked ODINFMT would
		# silently retarget every case after this one, and a leaked CI would flip
		# the whole pin policy.
		foreach ($name in $restore.Keys) {
			$value = $restore[$name]
			if ($null -eq $value) { $value = '' }
			Set-Item -LiteralPath "env:$name" -Value $value
		}
	}

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
		[switch] $MergeStreams,
		[hashtable] $Environment = @{}
	)

	return Wait-FixtureScript -TimeoutSeconds $TimeoutSeconds -Run (Start-FixtureScript -RepoRoot $RepoRoot `
			-Script $Script -ScriptArguments $ScriptArguments -MergeStreams:$MergeStreams -Environment $Environment)
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

# Every top-level procedure in one file, measured the way CLAUDE.md rule F1
# measures: from the line carrying `::` through the closing brace, comments and
# blanks included.
#
# The boundaries come from Get-OdinProcedureRange in common.ps1 rather than from
# a second scan here. They were two, and the copy in this file was the older and
# blinder of them -- it read a column-0 `}` inside a raw string as the end of a
# procedure. Rule F1's limit and section 0's comment ban are two questions about
# one set of boundaries, so there is one reader that answers where a procedure
# starts and stops, and this is the arithmetic F1 does on the answer.
function Get-OdinProcedureLength {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	return @(Get-OdinProcedureRange -Text $Text | ForEach-Object {
			[pscustomobject]@{ Name = $_.Name; Lines = ($_.End - $_.Start + 1) }
		})
}

# The <package>.<test> names a document hands a reader to run, in every spelling
# PowerShell itself binds: a space or a colon before the value, the value quoted
# either way, and any casing -- [regex]::Matches is case-SENSITIVE, so `-testname`
# read as no command at all. The dot is what keeps prose about the flag
# ("-TestName takes <package>.<test>") from reading as a name.
# The .odin files a case reads, refused when discovery finds none.
#
# Five cases below open by asking for them, and every one of them is worthless
# against an empty answer -- which is this suite's whole subject: a sweep exiting
# 0 having run nothing, a suite announcing all zero cases passed. Written out per
# case, the guard was five chances to leave it out of the sixth. The verb is the
# only part that differed.
function Get-CaseSource {
	param([Parameter(Mandatory)] [string] $Having)

	$sources = @(Get-OdinSource)
	if ($sources.Count -eq 0) {
		throw "no .odin files under $RepoRoot, so this case would pass having $Having nothing."
	}
	return $sources
}

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
#
# $OdinSweepTimeoutSeconds now bounds the FORMAT sweep as well as the test sweep,
# so this arithmetic answers for both. The behaviour each of them gets out of it
# is pinned separately, by a case apiece.
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
	# whenever the file is missing or json.unmarshal fails, and says NOTHING --
	# which would leave every command here passing against a style nobody chose,
	# and that default is platform-dependent, so it would not even be the same
	# style twice.
	$missing = New-FixtureRepo 'format-config-missing'
	Add-FixtureBinary -RepoRoot $missing -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Remove-Item -LiteralPath (Join-Path $missing 'odinfmt.json') -Force
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $missing -Script 'format.ps1') -Fails -Matching 'no .*odinfmt\.json'

	$broken = New-FixtureRepo 'format-config-broken'
	Add-FixtureBinary -RepoRoot $broken -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	[System.IO.File]::WriteAllText((Join-Path $broken 'odinfmt.json'), '{ "character_width": 100, oops }', $Utf8NoBom)
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $broken -Script 'format.ps1') -Fails -Matching 'not valid JSON'

	# And the same refusal for a config odinfmt would have read perfectly well.
	# A trailing comma is the likeliest syntax error there is, and it is NOT one
	# of the silent-default cases above: odinfmt reads this file with
	# core:encoding/json, whose DEFAULT_SPECIFICATION is JSON5, and measured
	# against the pinned build a trailing comma and a // comment both parse and
	# apply IN FULL -- byte-identical output to the same config without them, and
	# different from the output with no config at all.
	#
	# So this refusal is the check being deliberately stricter than odinfmt, which
	# is the fail-closed answer: `{ "character_width": 100, oops }` above and this
	# file are the same file to anything reading it here, and nothing on disk says
	# which way odinfmt went. The refusal has to say THAT, and not the opposite.
	$tolerated = New-FixtureRepo 'format-config-trailing-comma'
	Add-FixtureBinary -RepoRoot $tolerated -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$path = Join-Path $tolerated 'odinfmt.json'
	# Built by hand rather than by regex: a `$`-anchored pattern does not match
	# what it looks like it matches once the file arrives with CRLF endings.
	$text = [System.IO.File]::ReadAllText($path)
	$brace = $text.LastIndexOf('}')
	if ($brace -lt 0) {
		throw "the fixture's odinfmt.json has no closing brace to put a comma in front of."
	}
	[System.IO.File]::WriteAllText($path, ($text.Substring(0, $brace).TrimEnd() + ",`n}`n"), $Utf8NoBom)

	$result = Invoke-FixtureScript -RepoRoot $tolerated -Script 'format.ps1'
	Assert-Result -Result $result -Fails -Matching 'not valid JSON'
	Assert-Result -Result $result -Fails -Matching 'JSON5'
	# The claim the refusal must not make, kept as its own assertion because it is
	# the whole finding: the message said odinfmt "would ignore it silently and
	# format to its own default instead", and for this file odinfmt does neither.
	if ($result.Output -match 'ignore it silently') {
		throw "the refusal still claims odinfmt ignores this config, which it measurably does not.`n$($result.Output)"
	}
}

# CLAUDE.md rule F1, in its own words: a hard limit, "checkable by machine and
# has no exceptions without a maintainer decision recorded at the site".
$OdinProcedureLineLimit = 70

Test-Case 'no procedure the format check covers is over the line limit' {
	# Measured over every file the FORMAT check covers, which is the scope that
	# moved: the audit behind this rule was scoped to src\, and then the formatter
	# was given authority over docs\reference\ as well. It reformatted the spike
	# there from 62 lines to 107 and nothing noticed, because nothing was looking
	# outside src\. The two scopes are the same scope now, by construction --
	# Get-OdinSource is what both of them ask.
	$sources = @(Get-CaseSource -Having 'measured')

	$measured = @()
	foreach ($source in $sources) {
		foreach ($procedure in @(Get-OdinProcedureLength -Text ([System.IO.File]::ReadAllText($source.Path)))) {
			$measured += [pscustomobject]@{ Where = "$($source.Name):$($procedure.Name)"; Lines = $procedure.Lines }
		}
	}
	if ($measured.Count -eq 0) {
		throw "read no procedures at all out of $($sources.Count) file(s), so this case measured nothing."
	}

	$over = @($measured | Where-Object { $_.Lines -gt $OdinProcedureLineLimit } | Sort-Object Lines -Descending)
	if ($over.Count -gt 0) {
		$named = ($over | ForEach-Object { "  - $($_.Where) is $($_.Lines) lines" }) -join "`n"
		throw "$($over.Count) procedure(s) over CLAUDE.md rule F1's $OdinProcedureLineLimit-line limit:`n$named"
	}

	# The negative space (rule A3), and not a formality: a reader that finds no
	# procedure at all, or one that never counts past the limit, satisfies every
	# line above. Both halves are checked against a procedure built to a known
	# length, so the expected number comes from how it was built and not from
	# running the same count twice.
	$long = "over :: proc() {`n" + (("`t// filler`n") * ($OdinProcedureLineLimit - 1)) + "}`n"
	$read = @(Get-OdinProcedureLength -Text $long)
	if ($read.Count -ne 1) {
		throw "read $($read.Count) procedures out of a text holding exactly one."
	}
	if ($read[0].Lines -ne ($OdinProcedureLineLimit + 1)) {
		throw "measured a $($OdinProcedureLineLimit + 1)-line procedure as $($read[0].Lines) lines."
	}

	# And a procedure TYPE, which carries no body and must not be measured as
	# though the next declaration's brace were its own.
	$bodyless = "Callback :: proc(held: int) -> bool`n`nCaller :: proc() {`n`treturn`n}`n"
	$names = @(Get-OdinProcedureLength -Text $bodyless | ForEach-Object { $_.Name })
	if (($names.Count -ne 1) -or ($names[0] -ne 'Caller')) {
		throw "reading a bodyless procedure type gave: $($names -join ', ')"
	}
}

# CLAUDE.md section 0, which until now nothing enforced. Rule F1 beside it is a
# hard limit a machine checks on every run; the comment ban was a sweep somebody
# performed once, and a rule enforced once is a snapshot -- the next body comment
# lands next week and nothing says so.
#
# One backtick, as a single-quoted string so nothing escapes it. The raw-string
# case below is the whole reason this reader is not a regex, and writing its
# fixture with `` in a double-quoted string is how that case comes to test the
# wrong text.
$Backtick = '`'

Test-Case 'no procedure the format check covers carries a comment in its body' {
	# Over every file the FORMAT check covers, which is the scope rule F1 already
	# learned the hard way: the audit behind the ban was scoped to src\, and
	# docs\reference\ kept two body comments nobody was looking at. Get-OdinSource
	# is what both checks ask, so the two scopes are the same scope by construction.
	$sources = @(Get-CaseSource -Having 'read')

	$found = @()
	foreach ($source in $sources) {
		foreach ($comment in @(Get-OdinBodyComment -Text ([System.IO.File]::ReadAllText($source.Path)))) {
			$found += "  - $($source.Name):$($comment.Line) in $($comment.Name): $($comment.Text)"
		}
	}
	if ($found.Count -gt 0) {
		throw "$($found.Count) comment(s) inside a procedure body (CLAUDE.md section 0):`n$($found -join "`n")"
	}

	# The negative space (rule A3). Every line above is satisfied by a reader that
	# finds nothing anywhere, so what it does find is checked against bodies built
	# to a known answer.
	$planted = "held :: proc() {`n`t// this one is banned`n`treturn`n}`n"
	$caught = @(Get-OdinBodyComment -Text $planted)
	if (($caught.Count -ne 1) -or ($caught[0].Name -ne 'held') -or ($caught[0].Line -ne 2)) {
		throw "a planted body comment read as: $($caught.Count) finding(s) $(($caught | ForEach-Object { "$($_.Name):$($_.Line)" }) -join ', ')"
	}

	# A `//` INSIDE a raw string is not a comment, and this is the case that
	# separates this reader from a grep: a backtick string spans lines, so the
	# middle line here begins at column 0 with two slashes and is transcribed text.
	# A checker fooled by it refuses a Recording for what somebody said.
	$rawString = @(
		'held :: proc() {'
		"`ttext := $Backtick"
		'// inside a raw string, so not a comment at all'
		"$Backtick"
		"`t_ = text"
		'}'
	) -join "`n"
	$fooled = @(Get-OdinBodyComment -Text $rawString)
	if ($fooled.Count -ne 0) {
		throw "a `$Backtick-quoted string holding two slashes was read as $($fooled.Count) body comment(s)."
	}

	# And the comment a procedure is ALLOWED: the one above it, explaining why.
	# Reading that as a body comment would fail every well-documented file in the
	# repository and make the check the first thing anybody turned off.
	$documented = "// why this procedure exists`nheld :: proc() {`n`treturn`n}`n"
	$overreach = @(Get-OdinBodyComment -Text $documented)
	if ($overreach.Count -ne 0) {
		throw "a comment ABOVE a procedure was read as $($overreach.Count) body comment(s)."
	}
}

Test-Case 'a comment that follows code on its line is still a comment in the body' {
	# The gap this case exists to close. The reader asked whether a line BEGAN with
	# a comment, so `x := 1 // why` passed a check whose refusal reads "N comment(s)
	# inside a procedure body" -- a complete-sounding guarantee over a partial scan.
	# That is the failure this repository keeps meeting from the other side: a sweep
	# exiting 0 having read nothing, a suite announcing all zero cases passed. The
	# tree carries no trailing comment today, so what this holds is the next one.
	$trailing = "held :: proc() {`n`tx := 1 // why`n`t_ = x`n}`n"
	$caught = @(Get-OdinBodyComment -Text $trailing)
	if (($caught.Count -ne 1) -or ($caught[0].Line -ne 2)) {
		throw "a trailing line comment read as: $($caught.Count) finding(s) on line(s) $(($caught | ForEach-Object { $_.Line }) -join ', ')"
	}

	# The same for the block form, which a reader anchored to the first token misses
	# the same way and which can then run on for the rest of the file.
	$block = "held :: proc() {`n`tx := 1 /* why */`n`t_ = x`n}`n"
	$caughtBlock = @(Get-OdinBodyComment -Text $block)
	if (($caughtBlock.Count -ne 1) -or ($caughtBlock[0].Line -ne 2)) {
		throw "a trailing block comment read as: $($caughtBlock.Count) finding(s) on line(s) $(($caughtBlock | ForEach-Object { $_.Line }) -join ', ')"
	}

	# The negative space (rule A3), and the reason widening the reader is not the
	# same as grepping a line for two slashes. A URL inside a string is not a
	# comment, and this repository writes strings holding whatever somebody said.
	$inString = @(
		'held :: proc() {'
		"`ts := `"https://example.com`""
		"`t_ = s"
		'}'
	) -join "`n"
	$fooledByString = @(Get-OdinBodyComment -Text $inString)
	if ($fooledByString.Count -ne 0) {
		throw "two slashes inside a string were read as $($fooledByString.Count) body comment(s)."
	}

	# Nor is a rune literal spelled '/' half of one -- and the escaped-quote rune
	# beside it is what stops the reader running off the end of the literal and
	# reading the rest of the line as text inside a string.
	$runes = @(
		'held :: proc() {'
		"`tslash := '/'"
		"`tquote := '\''"
		"`t_, _ = slash, quote"
		'}'
	) -join "`n"
	$fooledByRune = @(Get-OdinBodyComment -Text $runes)
	if ($fooledByRune.Count -ne 0) {
		throw "rune literals '/' and '\'' were read as $($fooledByRune.Count) body comment(s)."
	}
}

Test-Case 'every procedure in the tree is declared where the two scans can see it' {
	# What the scan actually reads is a declaration at COLUMN ZERO, which is what
	# separates a procedure from the `proc(...) ---` entries indented inside a
	# foreign block. A procedure declared inside a `when` block is indented too, and
	# the scan does not see it AT ALL -- not its comments for section 0, and not its
	# length for rule F1, which reads the same boundaries.
	#
	# So the gap is closed from the other end: nothing may be declared where the
	# scan cannot look. The tree has no such declaration today and this case finds
	# none, which is exactly when a limitation goes unrecorded and turns into a
	# silent false negative later. Hoist it to column zero, or teach both scans.
	$sources = @(Get-CaseSource -Having 'read')

	$hidden = @()
	foreach ($source in $sources) {
		foreach ($procedure in @(Get-OdinHiddenProcedure -Text ([System.IO.File]::ReadAllText($source.Path)))) {
			$hidden += "  - $($source.Name):$($procedure.Line) declares $($procedure.Name)"
		}
	}
	if ($hidden.Count -gt 0) {
		throw "$($hidden.Count) procedure(s) declared where Get-OdinProcedureRange cannot see them:`n$($hidden -join "`n")"
	}

	# The negative space (rule A3). Every line above is satisfied by a reader that
	# finds nothing anywhere, so both answers are checked against text built to a
	# known one: a `when` block hides a procedure, and a foreign block does not.
	$hiddenByWhen = @(
		'when ODIN_OS == .Windows {'
		"`thelper :: proc() {"
		"`t`t// invisible to a column-zero scan"
		"`t}"
		'}'
	) -join "`n"
	$read = @(Get-OdinHiddenProcedure -Text $hiddenByWhen)
	if (($read.Count -ne 1) -or ($read[0].Name -ne 'helper') -or ($read[0].Line -ne 2)) {
		throw "a procedure inside a when block read as: $($read.Count) finding(s) $(($read | ForEach-Object { "$($_.Name):$($_.Line)" }) -join ', ')"
	}

	$foreign = @(
		'foreign import kernel32 "system:Kernel32.lib"'
		''
		'@(default_calling_convention = "std")'
		'foreign kernel32 {'
		"`tGetTickCount64 :: proc() -> u64 ---"
		'}'
	) -join "`n"
	$overreach = @(Get-OdinHiddenProcedure -Text $foreign)
	if ($overreach.Count -ne 0) {
		throw "a foreign block's bodyless entries read as $($overreach.Count) hidden procedure(s)."
	}
}

Test-Case 'a procedure TYPE is not read as a procedure with a body' {
	# A procedure TYPE has no body, so every question the three checks ask about a
	# body is unanswerable about one: it has no length for rule F1 to measure, no
	# lines for section 0 to find comments in, and no call site for rule F2's
	# attribute to fail -- the compiler REFUSES @(require_results) on a type,
	# `Unknown attribute element name`, so a demand for it is a build that cannot
	# be made to pass without deleting code.
	#
	# The fixture is the shape issue #36's shared fault report produces and that
	# src\process\command_line.odin and src\transcript\engine_json.odin carry
	# today: a fault-facts signature above a `:=` table. What made the reader
	# misread it is that the table's `FAULT :=` is not a `::` declaration, so the
	# hunt for the closing brace walked straight past it and stopped at the
	# table's -- handing all three checks a procedure eight lines long that does
	# not exist.
	$shape = @(
		'Fault_Says :: proc(fault: Build_Fault) -> string'
		''
		'// See CLAUDE.md, Odin notes: enumerated arrays and switches.'
		'FAULT := [Build_Fault]Fault_Facts {'
		"`t// the success value, which the renderer refuses by name"
		"`t.None = {},"
		'}'
	) -join "`n"

	$measured = @(Get-OdinProcedureRange -Text $shape)
	if ($measured.Count -ne 0) {
		throw "a procedure type read as $($measured.Count) procedure(s) with a body, spanning $(($measured | ForEach-Object { $_.End - $_.Start + 1 }) -join ', ') line(s)."
	}
	$inTable = @(Get-OdinBodyComment -Text $shape)
	if ($inTable.Count -ne 0) {
		throw "$($inTable.Count) comment(s) in a top-level table read as comments inside a procedure body."
	}
	$demanded = @(Get-OdinResultProcedure -Text $shape)
	if ($demanded.Count -ne 0) {
		throw "a procedure type was asked to carry an attribute the compiler refuses on one: $(($demanded | ForEach-Object { $_.Name }) -join ', ')."
	}

	# The same signature above a top-level `when` block, which is the other thing
	# that follows one at column 0 without being a `::` declaration.
	$aboveWhen = @(
		'Fault_Says :: proc(fault: Build_Fault) -> string'
		''
		'when ODIN_OS == .Windows {'
		"`tSEPARATOR :: `"\\`""
		'}'
	) -join "`n"
	$overreach = @(Get-OdinResultProcedure -Text $aboveWhen)
	if ($overreach.Count -ne 0) {
		throw "a procedure type above a when block read as $($overreach.Count) returning procedure(s)."
	}

	# The negative space (rule A3). Every line above is satisfied by a reader that
	# has stopped finding procedures at all, so the body it must still find is
	# checked beside the type it must not: same name, same signature, one brace of
	# difference, and only the second is a procedure.
	$body = @(
		'Fault_Says :: proc(fault: Build_Fault) -> string {'
		"`treturn `"broken`""
		'}'
	) -join "`n"
	$found = @(Get-OdinProcedureRange -Text $body)
	if (($found.Count -ne 1) -or ($found[0].Name -ne 'Fault_Says') -or ($found[0].End -ne 2)) {
		throw "the same signature WITH a body read as: $($found.Count) procedure(s) $(($found | ForEach-Object { "$($_.Name)[$($_.Start)..$($_.End)]" }) -join ', ')"
	}
	$still = @(Get-OdinResultProcedure -Text $body)
	if (($still.Count -ne 1) -or $still[0].Required) {
		throw "the same signature WITH a body read as: $($still.Count) returning procedure(s), Required=$($still.Required)"
	}

	# A `where` clause is the one thing that may sit between a complete signature
	# and the brace, so it is the one continuation the header reader looks for --
	# and it fails in the SILENT direction: a clause on its own line would end the
	# header early, the procedure would read as a type, and all three checks would
	# stop seeing it without any of them reporting anything. The tree carries no
	# `where` clause today, which is exactly when a rule goes untested and the
	# first one somebody writes disappears from the build.
	$clause = @(
		'adds :: proc(a: $T, b: T) -> T'
		"`twhere intrinsics.type_is_numeric(T) {"
		"`treturn a + b"
		'}'
	) -join "`n"
	$constrained = @(Get-OdinResultProcedure -Text $clause)
	if (($constrained.Count -ne 1) -or ($constrained[0].Name -ne 'adds')) {
		throw "a where clause on its own line read as: $($constrained.Count) returning procedure(s) $(($constrained | ForEach-Object { $_.Name }) -join ', ')"
	}

	$listed = @(
		'adds :: proc(a: $T, b: T) -> T'
		"`twhere intrinsics.type_is_numeric(T),"
		"`t`tintrinsics.type_is_ordered(T) {"
		"`treturn a + b"
		'}'
	) -join "`n"
	$multi = @(Get-OdinResultProcedure -Text $listed)
	if (($multi.Count -ne 1) -or ($multi[0].Name -ne 'adds')) {
		throw "a where clause over two lines read as: $($multi.Count) returning procedure(s) $(($multi | ForEach-Object { $_.Name }) -join ', ')"
	}
}

Test-Case 'a comment inside a procedure body fails the build' {
	# Rule S1's formatting check fails the BUILD rather than a step somebody
	# remembers to run, and section 0 is enforced the same way for the same reason.
	# The fixture is otherwise the binary every other build case uses: it still
	# prints the banner and still exits zero, so what fails here is the comment and
	# nothing the compiler would have caught anyway.
	$repo = New-FixtureRepo 'build-body-comment'
	$commented = "import `"core:fmt`"`n`nmain :: proc() {`n`t// banned by CLAUDE.md section 0`n`tfmt.println(`"$SmokeBanner`")`n}`n"
	Add-FixtureBinary -RepoRoot $repo -Body $commented | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'inside a procedure body'
	# The LINE and not merely the file. A checker that names the file it found
	# something in is a checker somebody has to go and search; the whole cost of
	# reading procedure ranges rather than grepping is paid to say where. Line 6 is
	# where Add-FixtureBinary's `package main` preamble puts the comment above.
	Assert-Result -Result $result -Fails -Matching 'main\.odin:6'
}

Test-Case 'the comment ban the build enforces is written down' {
	# The rule and its enforcement, pinned to each other. This is the defect that
	# produced the check above: the ban was applied to 53 files by a branch that
	# also deleted the section stating it, so the tree arrived shaped by a rule
	# written down nowhere and the next contributor could not learn it existed.
	# A check with no policy behind it is a check somebody deletes as unexplained.
	$policy = Join-Path $RepoRoot 'CLAUDE.md'
	if (-not (Test-Path -LiteralPath $policy)) {
		throw "no $policy, so the rule Assert-OdinCommentPolicy enforces is stated nowhere."
	}

	$text = [System.IO.File]::ReadAllText($policy)
	foreach ($claim in @('## 0. Comment policy', 'Comments are banned inside procedure bodies.')) {
		if (-not $text.Contains($claim)) {
			throw "CLAUDE.md does not carry '$claim', but scripts\common.ps1 fails the build over it."
		}
	}
}

Test-Case 'no procedure the format check covers hands back an unrequired answer' {
	# CLAUDE.md rule F2, over the same scope rule F1 and section 0 read, and here
	# for the direction `@(require_results)` cannot cover on its own: the attribute
	# fails a call site that DROPS an answer, and the compiler refuses it on a
	# procedure with no results -- so the procedure declared tomorrow that returns
	# a fault and never carries it is a rule nothing checks. That is the direction
	# every bare one here arrived from (issue #43).
	$sources = @(Get-CaseSource -Having 'read')

	$read = 0
	$annotated = 0
	$bare = @()
	foreach ($source in $sources) {
		$text = [System.IO.File]::ReadAllText($source.Path)
		foreach ($procedure in @(Get-OdinResultProcedure -Text $text)) {
			$read += 1
			if (-not $procedure.Required) {
				$bare += "  - $($source.Name):$($procedure.Line) $($procedure.Name)"
			}
		}
		# Counted off the LINES, by a reader that knows nothing about procedures --
		# so it cannot agree with the one above by sharing its mistake.
		foreach ($fact in @(Get-OdinLineFact -Text $text)) {
			if (($fact.Code -match '^@') -and ($fact.Code -match '\brequire_results\b')) {
				$annotated += 1
			}
		}
	}

	# The vacuous-pass guard lives HERE and not in Assert-OdinResultPolicy, which
	# runs against whatever repository it is pointed at: a program whose every
	# procedure returns nothing is ordinary, and every build fixture below is one.
	#
	# Against the ATTRIBUTE COUNT and not against zero. `$read -eq 0` is the guard
	# for a reader that broke completely, and a reader that breaks completely is
	# the one failure nothing needed a guard to notice. What it let through is a
	# reader that finds five procedures out of hundreds -- still non-zero, still
	# green, and blind to everything it did not reach. Every attribute in the tree
	# sits above a procedure this must have found returning, so the two numbers
	# have to meet; the count is not written down here, so adding a procedure does
	# not edit this case.
	if ($annotated -eq 0) {
		throw "no @(require_results) anywhere in $($sources.Count) file(s), so this case has no independent count to check the reader against."
	}
	if ($read -lt $annotated) {
		throw "read $read returning procedure(s) against $annotated @(require_results) attribute(s) in the same files, so the reader is not seeing every procedure an attribute was written for."
	}
	if ($bare.Count -gt 0) {
		throw "$($bare.Count) procedure(s) return without @(require_results) (CLAUDE.md rule F2):`n$($bare -join "`n")"
	}

	# The negative space (rule A3). Every line above is satisfied by a reader that
	# finds nothing anywhere, so both answers are checked against text built to a
	# known one.
	$plain = "answers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$caught = @(Get-OdinResultProcedure -Text $plain)
	if (($caught.Count -ne 1) -or ($caught[0].Name -ne 'answers') -or $caught[0].Required) {
		throw "a bare returning procedure read as: $($caught.Count) finding(s), Required=$($caught.Required)"
	}

	# Stacked above @(private), which is the shape most of this tree carries.
	$stacked = "@(private)`n@(require_results)`nanswers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$satisfied = @(Get-OdinResultProcedure -Text $stacked)
	if (($satisfied.Count -ne 1) -or (-not $satisfied[0].Required)) {
		throw "an annotated procedure read as: $($satisfied.Count) finding(s), Required=$($satisfied.Required)"
	}

	# The comment a procedure is ALLOWED, sitting where the rest of this file puts
	# it: between the attribute and the declaration. Reading the raw line rather
	# than its code reported this as bare, in a message telling somebody to put the
	# attribute above the declaration where it already was -- a refusal with no
	# action behind it, which is worse than no refusal.
	$explained = "@(require_results)`n// why this exists`nanswers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$read = @(Get-OdinResultProcedure -Text $explained)
	if (($read.Count -ne 1) -or (-not $read[0].Required)) {
		throw "an attribute above a comment above the declaration read as: $($read.Count) finding(s), Required=$($read.Required)"
	}

	# The block form of the same, which runs on past the line it opens on.
	$blockExplained = "@(require_results)`n/* why this exists`n   over two lines */`nanswers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$readBlock = @(Get-OdinResultProcedure -Text $blockExplained)
	if (($readBlock.Count -ne 1) -or (-not $readBlock[0].Required)) {
		throw "an attribute above a block comment above the declaration read as: $($readBlock.Count) finding(s), Required=$($readBlock.Required)"
	}

	# And the spelling the compiler's own core\odin\parser\file_tags.odin uses.
	# odinfmt rewrites it to the parenthesised form and runs first, so a reader
	# that knew only one spelling would be right only about formatted files.
	$bareSpelling = "@require_results`nanswers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$readBare = @(Get-OdinResultProcedure -Text $bareSpelling)
	if (($readBare.Count -ne 1) -or (-not $readBare[0].Required)) {
		throw "the bare @require_results spelling read as: $($readBare.Count) finding(s), Required=$($readBare.Required)"
	}

	# The negative space for all three (rule A3): a comment above a declaration
	# with NO attribute anywhere is still bare, and an attribute that is really
	# text inside a raw string is not one.
	$commentOnly = "// why this exists`nanswers :: proc(x: int) -> bool {`n`treturn x > 0`n}`n"
	$stillBare = @(Get-OdinResultProcedure -Text $commentOnly)
	if (($stillBare.Count -ne 1) -or $stillBare[0].Required) {
		throw "a comment with no attribute above it read as: $($stillBare.Count) finding(s), Required=$($stillBare.Required)"
	}

	$quoted = @(
		"TEXT :: $Backtick"
		'@(require_results)'
		"$Backtick"
		'answers :: proc(x: int) -> bool {'
		"`treturn x > 0"
		'}'
	) -join "`n"
	$fooledByRaw = @(Get-OdinResultProcedure -Text $quoted)
	if (($fooledByRaw.Count -ne 1) -or $fooledByRaw[0].Required) {
		throw "an attribute inside a raw string read as: $($fooledByRaw.Count) finding(s), Required=$($fooledByRaw.Required)"
	}

	# A procedure with NO results, which this must never name: the compiler refuses
	# the attribute there outright, so a false positive here is a demand the
	# toolchain will not let anybody satisfy.
	$silent = "shouts :: proc(x: int) {`n`t_ = x`n}`n"
	$overreach = @(Get-OdinResultProcedure -Text $silent)
	if ($overreach.Count -ne 0) {
		throw "a procedure returning nothing read as $($overreach.Count) returning procedure(s)."
	}

	# And the case that separates this reader from a search for two characters: the
	# only `->` here belongs to a PARAMETER that is itself a procedure, one level
	# in, and the procedure declared returns nothing at all.
	$callback = "takes :: proc(cb: proc(x: int) -> int) {`n`t_ = cb`n}`n"
	$fooled = @(Get-OdinResultProcedure -Text $callback)
	if ($fooled.Count -ne 0) {
		throw "a procedure-typed parameter's own `-> read as $($fooled.Count) returning procedure(s)."
	}

	# A header broken over lines, which is what odinfmt writes for anything wide --
	# and most of this tree's returning procedures are wide.
	$wrapped = "wide :: proc(`n`ta: int,`n`tb: int,`n) -> (`n`tsum: int,`n`tok: bool,`n) {`n`treturn a + b, true`n}`n"
	$long = @(Get-OdinResultProcedure -Text $wrapped)
	if (($long.Count -ne 1) -or ($long[0].Name -ne 'wide') -or $long[0].Required) {
		throw "a wrapped header read as: $($long.Count) finding(s) $(($long | ForEach-Object { $_.Name }) -join ', ')"
	}
}

Test-Case 'a procedure that returns without the attribute fails the build' {
	# Rule S1's formatting check and section 0's comment ban both fail the BUILD
	# rather than a step somebody remembers to run, and rule F2 is enforced the
	# same way for the same reason. The fixture still prints the banner and still
	# exits zero: what fails here is the missing attribute and nothing the
	# compiler would have caught anyway -- it never gets as far as the compiler.
	$repo = New-FixtureRepo 'build-unrequired-result'
	$returning = "import `"core:fmt`"`n`nbanner :: proc() -> string {`n`treturn `"$SmokeBanner`"`n}`n`nmain :: proc() {`n`tfmt.println(banner())`n}`n"
	Add-FixtureBinary -RepoRoot $repo -Body $returning | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'CLAUDE\.md rule F2'
	# The LINE and the NAME, not merely the file, for the reason the comment ban
	# names both: a checker somebody has to go and search for is a checker nobody
	# runs. Line 5 is where Add-FixtureBinary's `package main` preamble and the
	# import above put the declaration.
	Assert-Result -Result $result -Fails -Matching 'main\.odin:5 banner'
}

Test-Case 'the result rule the build enforces is written down' {
	# The rule and its enforcement, pinned to each other, exactly as the comment
	# ban above is and for the defect that produced that case: a tree shaped by a
	# rule written down nowhere is a tree whose next contributor cannot learn the
	# rule exists, and a check with no policy behind it is a check somebody deletes
	# as unexplained.
	$policy = Join-Path $RepoRoot 'CLAUDE.md'
	if (-not (Test-Path -LiteralPath $policy)) {
		throw "no $policy, so the rule Assert-OdinResultPolicy enforces is stated nowhere."
	}

	$text = [System.IO.File]::ReadAllText($policy)
	# The discard spelling is pinned twice over, because the attribute changes what
	# a `defer` has to look like and nothing else in the tree would say so: no site
	# hits it today, so the first person to write `defer f()` over an annotated
	# procedure meets a compiler error with no rule behind it.
	$claims = @(
		'### F2. `@(require_results)` on every procedure that returns anything'
		'spells it `_ = f(...)`'
		'`defer _ = f()`'
	)
	foreach ($claim in $claims) {
		if (-not $text.Contains($claim)) {
			throw "CLAUDE.md does not carry '$claim', but scripts\common.ps1 fails the build over it."
		}
	}
}

Test-Case 'git checks out every .odin file with the endings the check demands' -MaySkip {
	# The formatting check compares BYTES, and odinfmt.json pins newline_style to
	# CRLF -- so what puts CRLF in a working tree decides whether this repository
	# builds at all. Nothing in the repository did. The blobs are stored LF, and
	# the only thing converting them on the way out was Git for Windows' SYSTEM
	# gitconfig setting core.autocrlf=true: a machine-global setting, on a machine
	# that happened to have it. `git -c core.autocrlf=false clone` produced a
	# checkout where all 13 files failed the check and build.ps1 refused to build
	# anything, and running the remedy the failure prints would have rewritten
	# every one of them to CRLF and flipped the object store for everybody else.
	#
	# Asked of GIT rather than read off .gitattributes, and per FILE rather than
	# per rule: what matters is the answer git's own attribute resolution gives for
	# each path the sweep covers, and a rule written for the wrong glob reads
	# perfectly well and matches nothing.
	if (-not (Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue)) {
		Skip-Case -Reason 'no git on PATH to ask what it would check out'
	}
	$inside = Read-NativeOutput -Command 'git' -TimeoutSeconds $FixtureTimeoutSeconds `
		-Arguments @('-C', $RepoRoot, 'rev-parse', '--is-inside-work-tree')
	if ($inside.TimedOut -or ($inside.ExitCode -ne 0) -or ($inside.Output -ne 'true')) {
		Skip-Case -Reason "$RepoRoot is not a git work tree, so there are no checkout rules to ask about"
	}

	$sources = @(Get-CaseSource -Having 'asked about')

	$asked = Read-NativeOutput -Command 'git' -TimeoutSeconds $FixtureTimeoutSeconds `
		-Arguments (@('-C', $RepoRoot, 'check-attr', 'eol', '--') + @($sources | ForEach-Object { $_.Name }))
	if ($asked.TimedOut) {
		throw "git check-attr did not finish within $FixtureTimeoutSeconds seconds."
	}
	if ($asked.ExitCode -ne 0) {
		throw "git check-attr exited $($asked.ExitCode).`n$($asked.Output)"
	}

	$answers = @($asked.Output -split "`r?`n" | Where-Object { $_ -ne '' })
	if ($answers.Count -ne $sources.Count) {
		throw "asked about $($sources.Count) files and git answered for $($answers.Count).`n$($asked.Output)"
	}
	$adrift = @($answers | Where-Object { $_ -notmatch ': eol: crlf$' })
	if ($adrift.Count -gt 0) {
		throw "$($adrift.Count) .odin file(s) have no eol=crlf rule in .gitattributes, so their line endings come from whatever core.autocrlf the machine happens to set:`n$($adrift -join "`n")"
	}

	# The negative space (rule A3). Without it this case passes for a reader that
	# cannot tell the answers apart -- and the fixtures are the proof, because
	# `**/fixtures/** -text` deliberately leaves them unconverted (ADR-0001).
	$fixture = 'src/transcript/fixtures/engine-output.json'
	$evidence = Read-NativeOutput -Command 'git' -TimeoutSeconds $FixtureTimeoutSeconds `
		-Arguments @('-C', $RepoRoot, 'check-attr', 'eol', '--', $fixture)
	if ($evidence.Output -match ': eol: crlf$') {
		throw "git says it converts $fixture, which .gitattributes exempts as evidence: $($evidence.Output)"
	}
}

# The repository's OWN odinfmt.json with one edit made to it, which is what
# keeps these cases about the edit. A config written from scratch here would
# pass or fail for reasons the real one never has.
function Edit-FixtureFormatConfig {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [scriptblock] $Edit
	)

	$path = Join-Path $RepoRoot 'odinfmt.json'
	$config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
	& $Edit $config
	[System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json), $Utf8NoBom)
}

Test-Case 'a config key odinfmt would not read fails the format command by name' {
	# The four ways a config goes wrong WITHOUT odinfmt saying anything, each
	# planted in the real file. None of them is caught by formatting something and
	# looking at the answer, which is what this check used to do: odinfmt's
	# built-in Windows default is already tabs, CRLF and character_width 100, so
	# on this platform formatting with the config and with no config at all is
	# byte-identical. `"tabs": "true"` passed that check green.
	#
	# Each case asserts the KEY is named. A refusal that does not say which key is
	# a refusal somebody has to bisect by hand -- which is what removing a key
	# used to give: "The property 'tabs' cannot be found on this object."
	$faults = @(
		@{
			Name    = 'wrong-type'
			Edit    = { param($c) $c.tabs = 'true' }
			Matches = "'tabs' is the string 'true'"
		}
		@{
			Name    = 'misspelled-key'
			Edit    = {
				param($c)
				$c.PSObject.Properties.Remove('character_width')
				$c | Add-Member -NotePropertyName 'character_widht' -NotePropertyValue 100
			}
			Matches = "'character_widht' is not a key odinfmt reads"
		}
		@{
			Name    = 'missing-key'
			Edit    = { param($c) $c.PSObject.Properties.Remove('tabs') }
			Matches = "'tabs' is missing"
		}
		@{
			Name    = 'unknown-enum-name'
			Edit    = { param($c) $c.newline_style = 'CR' }
			Matches = "'newline_style' is the string 'CR'"
		}
	)

	foreach ($fault in $faults) {
		$repo = New-FixtureRepo "format-config-$($fault.Name)"
		Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
		Edit-FixtureFormatConfig -RepoRoot $repo -Edit $fault.Edit
		$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1'
		Assert-Result -Result $result -Fails -Matching ([regex]::Escape($fault.Matches))
	}

	# The negative space (rule A3). Every refusal above is satisfied by a check
	# that refuses every config there is -- including this repository's own, which
	# is the one config that has to pass. Written through the same editor that
	# planted the faults, so a helper that corrupts the file on the way through
	# cannot make the four cases above pass for the wrong reason.
	$sound = New-FixtureRepo 'format-config-sound'
	Add-FixtureBinary -RepoRoot $sound -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Edit-FixtureFormatConfig -RepoRoot $sound -Edit { param($c) $c.tabs = $true }
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $sound -Script 'format.ps1') `
		-Matching 'are formatted as odinfmt\.json says'
}

# Where a run of NUL-terminated names sits inside a byte image, and how many
# places it sits in. The names must be adjacent and in the order given.
#
# Odin emits the field names of every type a program reflects over as
# NUL-terminated strings, laid down contiguously and in declaration order, so a
# struct's field names appear in the binary as exactly one such run. Searching
# for the run is therefore a question the binary can answer NO to.
function Find-ByteRun {
	param(
		[Parameter(Mandatory)] [string] $Image,
		[Parameter(Mandatory)] [string[]] $Names
	)

	$needle = ($Names -join "`0") + "`0"
	$offsets = @()
	$at = 0
	while ($true) {
		$at = $Image.IndexOf($needle, $at, [System.StringComparison]::Ordinal)
		if ($at -lt 0) {
			break
		}
		$offsets += $at
		$at += 1
	}
	return [pscustomobject]@{ Offsets = $offsets; Length = $needle.Length }
}

Test-Case 'the config schema is the key set inside the pinned odinfmt' -MaySkip {
	# $OdinFormatConfigSchema was read out of the pinned binary once, by hand, and
	# then nothing held it there. The comment beside it claimed that "if a future
	# ols adds a key, odinfmt.json fails here naming it", and it would not have:
	# the check compares odinfmt.json against the schema, and both are files in
	# this repository. Dropping a key from the schema and from odinfmt.json
	# together -- which is exactly the shape of a sixteenth key arriving upstream
	# -- left format.ps1 exiting 0, naming nothing, with odinfmt quietly applying
	# its own default for the key nobody had listed.
	#
	# So the schema is checked against the binary it was read out of, which is
	# what makes moving the pin a decision about the schema too. Deterministic by
	# construction: the binary is pinned by CONTENT, so while the pin holds this
	# case is a fixed question about a fixed byte string and cannot flake. The
	# only thing that can turn it red is the pin moving -- which is the moment
	# somebody is supposed to look.
	$odinfmt = Resolve-OdinFormatter -Optional
	if ($odinfmt -eq '') {
		Skip-Case 'odinfmt is not installed, and this case is a claim about the pinned build.'
	}
	$found = Get-FileSha256 -Path $odinfmt
	if ($found -ne $OdinfmtSha256) {
		Skip-Case "$odinfmt hashes to $found, not the pinned $OdinfmtSha256, and only the pinned build can answer this."
	}

	# Latin-1, alone among the encodings, maps every one of the 256 byte values to
	# exactly one character and back. Decoding the image through it turns a byte
	# search into IndexOf; UTF-8 would fold invalid sequences onto U+FFFD and lose
	# the very bytes being searched for.
	$bytes = [System.IO.File]::ReadAllBytes($odinfmt)
	$image = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)

	$keys = @($OdinFormatConfigSchema.Keys)
	if ($keys.Count -lt 2) {
		throw "the schema declares $($keys.Count) key(s), so this case would be searching for almost nothing."
	}

	$run = Find-ByteRun -Image $image -Names $keys
	if ($run.Offsets.Count -ne 1) {
		throw "the $($keys.Count) schema keys do not appear in $odinfmt as one contiguous run in that order (found $($run.Offsets.Count) such runs). printer.Config has been renamed, reordered, or had a key added in the middle of it: read the field list out of the newly pinned build and move `$OdinFormatConfigSchema with the pin."
	}

	# And nothing follows them. The run above is satisfied by a printer.Config
	# that STARTS with these fifteen keys, which is exactly what a sixteenth key
	# appended upstream would look like -- and an unlisted key is the harmful
	# direction, because odinfmt fills it from its own default in silence while
	# every check here passes. A sixteenth name is emitted directly after the
	# fifteenth, so this byte is either the padding that ends the run or the first
	# letter of a key nobody chose.
	$after = $run.Offsets[0] + $run.Length
	if ($after -ge $bytes.Length) {
		throw "the schema's key run ends at the very end of $odinfmt, which is not a layout this case knows how to read."
	}
	if ($bytes[$after] -ne 0) {
		$next = ($image.Substring($after, [math]::Min(40, $bytes.Length - $after)) -split "`0")[0]
		throw "printer.Config carries at least one key past the $($keys.Count) in `$OdinFormatConfigSchema -- the name after '$($keys[-1])' is '$next'. An unlisted key takes odinfmt's own default in silence: add it to the schema and to odinfmt.json."
	}

	# The enum members too, and for the same reason in reverse. A member RENAMED
	# upstream leaves odinfmt.json naming one that no longer exists, which odinfmt
	# answers by leaving the field at its default and saying nothing, while the
	# check here passes -- brace_style is "_1TBS" in this repository's own config,
	# so that is a live path and not a hypothetical.
	#
	# Not bounded the way the keys are: a member ADDED upstream can only ever be
	# refused here, and a refusal is somebody reading this comment rather than a
	# style nobody chose.
	foreach ($key in $keys) {
		$expected = $OdinFormatConfigSchema[$key]
		if (($expected -eq 'int') -or ($expected -eq 'bool')) {
			continue
		}
		$members = @($expected -split '\|')
		$enum = Find-ByteRun -Image $image -Names $members
		if ($enum.Offsets.Count -ne 1) {
			throw "the names '$($members -join ", ")' the schema accepts for '$key' do not appear in $odinfmt as one contiguous run in that order (found $($enum.Offsets.Count) such runs). Read the enum out of the newly pinned build and move `$OdinFormatConfigSchema with the pin."
		}
	}
}

Test-Case 'a formatter that is not installed warns the build locally and stops it under CI' {
	# The asymmetry this closes ran the wrong way round. A formatter whose build
	# did not match the SHA-256 pin warned and carried on; a formatter that was
	# not installed at all failed the build outright -- so a contributor with the
	# pinned compiler but without the ols zip could not build anything, which is
	# the exact outcome the pin policy argues against.
	#
	# A path that is not there rather than an unset variable, because the fallback
	# location and PATH are both outside this suite's control: the development
	# machine has odinfmt at C:\Odin\dist\, and a case that turned on its absence
	# would pass there for the wrong reason.
	$absent = Join-Path $FixtureRoot 'no-such-odinfmt.exe'
	if (Test-Path -LiteralPath $absent) {
		throw "$absent exists, so this case cannot ask for a formatter that is missing."
	}

	# CI unset, whatever this suite is itself running under: on a CI runner
	# $env:CI is set for every case, and without this the local half would be
	# measuring the CI half.
	$local = New-FixtureRepo 'formatter-absent-local'
	Add-FixtureBinary -RepoRoot $local -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$built = Invoke-FixtureScript -RepoRoot $local -Script 'build.ps1' -Environment @{ ODINFMT = $absent; CI = '' }
	Assert-Result -Result $built -Matching 'NOT CHECKED'
	# Built, not merely warned about: the whole point is that the build finishes.
	Assert-Result -Result $built -Matching "printed: $([regex]::Escape($SmokeTarget.Name)) 0\.1\.0"

	# And CI refuses, which is what makes the local warning affordable.
	$ci = New-FixtureRepo 'formatter-absent-ci'
	Add-FixtureBinary -RepoRoot $ci -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Assert-Result -Fails -Matching 'BUILD FAILED' -Result (Invoke-FixtureScript -RepoRoot $ci `
			-Script 'build.ps1' -Environment @{ ODINFMT = $absent; CI = '1' })

	# The format command has nothing to do without a formatter, so asking it to
	# run is a request that can only be refused -- locally too. Without this the
	# change above would read as "a missing formatter is never an error".
	$asked = New-FixtureRepo 'formatter-absent-asked'
	Add-FixtureBinary -RepoRoot $asked -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Assert-Result -Fails -Matching 'no file is there' -Result (Invoke-FixtureScript -RepoRoot $asked `
			-Script 'format.ps1' -Environment @{ ODINFMT = $absent; CI = '' })
}

Test-Case 'a file odinfmt cannot parse fails the format command by name' {
	# odinfmt does NOT exit non-zero on a file it cannot parse. Measured against
	# the pinned build: exit ZERO, an empty standard output, and the diagnostic on
	# standard error. The guard that claimed otherwise never fired, and what
	# stopped the run instead was Set-StrictMode several frames later, reporting
	# "The property 'Length' cannot be found on this object" and naming no file.
	$repo = New-FixtureRepo 'format-unparseable'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$dir = Join-Path (Join-Path $repo 'src') 'unreadable'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'unreadable.odin') -Text "package unreadable`n`nthis is not Odin at all {`n"

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1'
	Assert-Result -Result $result -Fails -Matching 'could not parse the file'
	# The file, by name. A refusal that names nothing is the failure this case is
	# about, not the exit code -- which the accident already produced.
	Assert-Result -Result $result -Fails -Matching 'unreadable\.odin'
}

Test-Case 'the format sweep gives up on its own budget rather than running forever' {
	# Each FILE was bounded and the sweep was not, which is the defect the test
	# sweep already had once: one file's ceiling times however many files exist is
	# not a bound anybody chose, and at thirteen files it was 130 minutes against
	# a 30-minute CI job. Past that line the report comes from GitHub's job
	# timeout, which names no file and prints no output.
	#
	# One second, so the budget is spent before the first file rather than by
	# waiting: the clock starts before the config is read, so any elapsed time at
	# all floors the remainder to zero.
	$repo = New-FixtureRepo 'format-sweep-budget'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1' -ScriptArguments @('-SweepTimeoutSeconds', '1')
	Assert-Result -Result $result -Fails -Matching "1-second budget ran out"
	# Naming the file it stopped at is the point: "something timed out" over a
	# sweep of every .odin file in the repository is not a report anyone can act on.
	Assert-Result -Result $result -Fails -Matching 'main\.odin'

	# The negative space (rule A3). Without it this case passes for a sweep that
	# has run out of budget before it starts, whatever the budget is.
	$roomy = New-FixtureRepo 'format-sweep-budget-ample'
	Add-FixtureBinary -RepoRoot $roomy -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $roomy -Script 'format.ps1') `
		-Matching 'are formatted as odinfmt\.json says'
}

Test-Case 'the format command rewrites exactly what it named' {
	$repo = New-FixtureRepo 'format-fix'
	$dir = Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMainUnsorted -Line $SmokeBanner)

	# What a hard-killed -Fix strands beside a source, planted before the sweep
	# runs. Write-FileAtomically deletes its staged file however the replace
	# ended, so the only way one survives is a run killed between the write and
	# the rename -- after which nothing names that file again. Get-OdinSource does
	# not discover it and .gitignore does not cover it, so `git status` shows it:
	# that is what makes it harmless, not what makes it somebody else's problem.
	$stranded = Join-Path $dir "main.odin.4242-$([System.Guid]::NewGuid().ToString('N'))$OdinFormatStagedSuffix"
	[System.IO.File]::WriteAllText($stranded, 'staged bytes from a run nobody waited for')
	(Get-Item -LiteralPath $stranded).LastWriteTime = (Get-Date).AddDays(-3)

	# And one belonging to a run that is still going. Reclaimed on AGE for exactly
	# this reason (rule A3, and the reason Remove-StaleTestArtefact was written
	# that way): a concurrent -Fix has a staged file seconds old, and a sweep that
	# took that one would corrupt the rewrite it belongs to.
	$live = Join-Path $dir "main.odin.4243-$([System.Guid]::NewGuid().ToString('N'))$OdinFormatStagedSuffix"
	[System.IO.File]::WriteAllText($live, 'staged bytes from a run still going')

	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1') -Fails

	if (Test-Path -LiteralPath $stranded) {
		throw "the sweep left a three-day-old staged file beside the source: $stranded"
	}
	if (-not (Test-Path -LiteralPath $live)) {
		throw "the sweep took a staged file a concurrent rewrite is still using: $live"
	}

	# Everything under src\ before the rewrite, so "exactly what it named" can be
	# checked against the tree and not only against the file. -Fix stages the new
	# bytes beside the source and swaps them in with File.Replace, and a staged
	# file left behind would be a `_bk` by another name -- the very thing the
	# rewrite path was written to avoid.
	$before = @(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Recurse -File -Force |
			ForEach-Object { $_.FullName } | Sort-Object)

	$fixed = Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1' -ScriptArguments @('-Fix')
	Assert-Result -Result $fixed -Matching 'rewrote'

	$after = @(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Recurse -File -Force |
			ForEach-Object { $_.FullName } | Sort-Object)
	if ($after.Count -ne $before.Count) {
		$added = @($after | Where-Object { $before -notcontains $_ })
		throw "the rewrite left $($added.Count) extra file(s) behind: $($added -join ', ')"
	}

	# The check after the fix, which is the only thing that makes -Fix worth
	# having: a rewrite the check still rejects is a rewrite to a third style.
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'format.ps1') -Matching 'are formatted as odinfmt.json says'

	# And it still compiles -- a formatter that produces something the vet set
	# rejects has fixed nothing.
	Assert-Result -Result (Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1')
}

# The identity NTFS gave a file, as whatever fsutil prints, or the empty string
# where the volume or the tool cannot say.
#
# Compared only against another reading of ITSELF, never against a literal, so
# neither the format of the number nor the localised words around it matter.
function Get-NtfsFileId {
	param([Parameter(Mandatory)] [string] $Path)

	$printed = fsutil file queryfileid "$Path" 2>$null
	if ($LASTEXITCODE -ne 0) {
		return ''
	}
	return (($printed -join ' ').Trim())
}

Test-Case 'the rewrite swaps a new file in rather than writing over the old one' -MaySkip {
	# Write-FileAtomically's whole argument is about a window nothing here can
	# open: a run killed midway through writing the destination. Staging a crash
	# inside a .NET call is not something this suite can do, so the atomicity
	# itself is not what is checked -- swapping File.Replace back for a plain
	# WriteAllBytes leaves every other case in this file green, which is exactly
	# the silent revert the argument at the site warns about.
	#
	# What IS checkable is the mechanism, and cheaply. A truncating write keeps
	# the file it writes into; a replace gives the name a different file
	# altogether, and NTFS says which happened. So this pins "the bytes arrived by
	# rename" without needing the crash that makes it matter.
	$dir = Join-Path $FixtureRoot 'atomic-rewrite'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	$target = Join-Path $dir 'target.odin'
	[System.IO.File]::WriteAllText($target, 'package before')

	$created = Get-NtfsFileId -Path $target
	if ($created -eq '') {
		Skip-Case "fsutil will not name the files on the volume holding $dir, so there is no identity here to watch."
	}

	# The control, and the negative space rule A3 asks for. Without it this case
	# passes for any file identity that happens to move, and says nothing about
	# WHY: a plain write keeps the file, which is the truncation window the
	# rewrite path exists to avoid.
	[System.IO.File]::WriteAllBytes($target, [System.Text.Encoding]::ASCII.GetBytes('package written over'))
	$overwritten = Get-NtfsFileId -Path $target
	if ($overwritten -ne $created) {
		throw "a plain WriteAllBytes changed the file's identity on this volume ($created -> $overwritten), so a changed identity proves nothing about how the rewrite below put its bytes there."
	}

	Write-FileAtomically -Path $target -Bytes ([System.Text.Encoding]::ASCII.GetBytes('package swapped in'))

	$swapped = Get-NtfsFileId -Path $target
	if ($swapped -eq $overwritten) {
		throw "the rewrite wrote over $target in place -- its identity is still $swapped. File.Replace has been swapped for a write that truncates first, and a run killed inside that write leaves a truncated .odin file with nothing to say so."
	}
	$landed = [System.IO.File]::ReadAllText($target)
	if ($landed -ne 'package swapped in') {
		throw "the rewrite left '$landed' in $target rather than the bytes it was given."
	}
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
