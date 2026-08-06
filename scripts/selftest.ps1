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

# The file tag every fixture source carries, resolved through the reader build.ps1
# checks with rather than spelled again here. Spelled twice, a second name added to
# that declaration would leave every build fixture failing rule M2 for a reason no
# case is about.
#
# Asked for a file of the shape every fixture plants -- a package source, never a
# `_test.odin`, whatever the fixture puts inside it. So the exemptions issues #45
# and #48 scope to test files are correctly absent here, and stay absent without
# this line being edited.
$FixtureVetTags = "#+vet $((Get-OdinRequiredVetTag -Name 'src/fixture/fixture.odin') -join ' ')"

# The policy tool every fixture's build command reads Odin with, built ONCE here
# and handed to the children through the environment.
#
# Around thirty cases below run the real build command inside a throwaway
# repository, and not one of those repositories carries a tools\policy of its own.
# Without this, every one of them would fail on a bootstrap with nothing to build
# rather than on the thing it is about -- and the suite would compile the same
# program thirty times to say so. Set on THIS process because a child inherits the
# environment at CreateProcess time and Start-Process has no way to pass one.
#
# The bootstrap is not skipped by this. It runs here, now, against the real
# tools\policy, and this line fails the whole suite if that does not build. The
# case that checks what a build does WITHOUT one unsets the variable for its own
# child.
$env:TRANSCIBR_POLICY = Resolve-OdinPolicyTool

$script:Failures = @()
$script:Skips = @()
$script:Passes = 0

# DECLARED, never counted from the cases that happened to run: a count taken
# from what ran cannot notice that nothing did. Keep it in step with the cases
# below -- a mismatch either way fails the run.
$ExpectedCaseCount = 74

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
	# Every root $OdinPackageRoots declares, because Get-OdinPackage refuses a
	# declared root that is not there -- a sweep quietly covering one root fewer
	# is the silence this suite exists to catch. Empty here: no fixture carries a
	# build tool of its own, and every case that runs the build command inherits
	# one already built (see $OdinPolicyOverride).
	foreach ($declared in $OdinPackageRoots) {
		$under = Get-RelativeName -Path $declared.Path -Root $RepoRoot
		New-Item -ItemType Directory -Path (Join-Path $root $under) -Force | Out-Null
	}
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
		[string] $Directory = '',
		# core:testing clamps thread_count = min(thread_count, total_test_count)
		# (runner.odin), so a single-test 'passing' package reports "1 thread"
		# whether or not -define:ODIN_TEST_THREADS=1 was passed. Only a 'passing'
		# package with two or more tests can tell the define apart from its
		# absence.
		[int] $PassingCount = 1
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
		'passing' {
			$procs = (1..$PassingCount | ForEach-Object {
					"@(test)`n${Name}_passes_$_ :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n}`n"
				}) -join "`n"
			"import `"core:testing`"`n`n$procs"
		}
		'failing' { "import `"core:testing`"`n`n@(test)`n${Name}_fails :: proc(t: ^testing.T) {`n`ttesting.expect(t, false, `"deliberate failure`")`n}`n" }
		'asserting' { "import `"core:testing`"`n`n$asserting" }
		'hanging' { "import `"core:testing`"`nimport `"core:time`"`n`n@(test)`n${Name}_never_returns :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n`tfor {`n`t`ttime.sleep(time.Second)`n`t}`n}`n" }
		'leaking' { "import `"core:testing`"`n`n@(test)`n${Name}_leaks :: proc(t: ^testing.T) {`n`tleaked := make([]u8, 8, context.allocator)`n`ttesting.expect(t, len(leaked) == 8)`n}`n" }
		'none' { "${Name}_CONSTANT :: 1`n" }
	}
	$source = "$FixtureVetTags`npackage $Name`n`n$body"
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
	Write-FixtureSource -Path (Join-Path $dir 'main.odin') -Text "$FixtureVetTags`npackage main`n`n$Body"
	return $dir
}

# The same binary padded to a chosen length: it prints the one line the smoke test
# reads and then discards a constant $Padding times, so `main` spans
# $Padding + 3 lines -- its declaration, its one print, the padding, and its
# closing brace. Rule F1's case is the only caller and both of its halves come
# from here, so the two differ by the number this takes and by nothing else.
function New-FixtureLongMain {
	param([Parameter(Mandatory)] [ValidateRange(1, 1000)] [int] $Padding)

	$discards = "`t_ = 1`n" * $Padding
	return "import `"core:fmt`"`n`nmain :: proc() {`n`tfmt.println(`"$SmokeBanner`")`n$discards}`n"
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

# The .odin files a case reads, refused when discovery finds none.
#
# Three cases below open by asking for them, and every one of them is worthless
# against an empty answer -- which is this suite's whole subject: a sweep exiting
# 0 having run nothing, a suite announcing all zero cases passed. Written out per
# case, the guard is one chance per case to leave it out of the next. The verb is
# the only part that differs.
function Get-CaseSource {
	param([Parameter(Mandatory)] [string] $Having)

	$sources = @(Get-OdinSource)
	if ($sources.Count -eq 0) {
		throw "no .odin files under $RepoRoot, so this case would pass having $Having nothing."
	}
	return $sources
}

# A rule and its enforcement, pinned to each other.
#
# This is the defect that produced the first of the five cases below: the
# comment ban was applied to 53 files by a branch that also deleted the section
# stating it, so the tree arrived shaped by a rule written down nowhere and the
# next contributor could not learn it existed. A check with no policy behind it
# is a check somebody deletes as unexplained.
#
# Written three times before somebody counted -- once per policy, which is once
# per chance to leave it out of the next one added -- and the network-confinement
# claim below is now its fifth caller, the same count Get-OdinCheckedSource
# reached for the same reason. $Enforcer is the only part that differed between
# them beyond the claims themselves.
function Assert-PolicyClaim {
	param(
		[Parameter(Mandatory)] [string] $Enforcer,
		[Parameter(Mandatory)] [string[]] $Claims,
		# CLAUDE.md by default -- every case here until issue #58's network claim,
		# which is stated in README.md instead. One parameter rather than a second
		# procedure: the two differ only in which file is read, and a second copy
		# is a second place for the "does not carry" message to drift from this one.
		[string] $Document = 'CLAUDE.md'
	)

	$policy = Join-Path $RepoRoot $Document
	if (-not (Test-Path -LiteralPath $policy)) {
		throw "no $policy, so the rule $Enforcer enforces is stated nowhere."
	}

	$text = [System.IO.File]::ReadAllText($policy)
	foreach ($claim in $Claims) {
		if (-not $text.Contains($claim)) {
			throw "$Document does not carry '$claim', but scripts\common.ps1 fails the build over it."
		}
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

# The ci.yml steps whose command is one CLAUDE.md documents a developer
# running locally -- the file's own header comment claim, "every check CI
# performs a developer performs too". Deleting one of these leaves every
# OTHER case in this file green: they call format.ps1, build.ps1 and
# test.ps1 directly, and nothing before this read what ci.yml itself runs
# (issue #116, filed from the #104 review). Not every step is here --
# `actions/checkout` and the two pinned-tool installs have no local command
# to be a claim about. Build (release) is included: -o:speed is a different
# code path through the compiler (build.ps1's own -Configuration branch),
# and a release that only builds at tagging time is a release that breaks
# at tagging time.
$LoadBearingCiSteps = @(
	[pscustomobject]@{ Name = 'Check formatting'; Run = '.\scripts\format.ps1' }
	[pscustomobject]@{ Name = 'Build (debug)'; Run = '.\scripts\build.ps1' }
	[pscustomobject]@{ Name = 'Build (release)'; Run = '.\scripts\build.ps1 -Configuration release' }
	[pscustomobject]@{ Name = 'Test'; Run = '.\scripts\test.ps1' }
	[pscustomobject]@{ Name = 'Test (child, single-threaded)'; Run = '.\scripts\test.ps1 -Threads1' }
)

# The names of $LoadBearingCiSteps whose "- name:" line is not immediately
# followed, before the next step, by its own "run:" line -- read off the raw
# YAML text rather than a parser, because the property under test is exactly
# what a line-oriented review of the diff would see: the step heading and the
# command underneath it, still paired.
function Get-MissingCiStep {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$missing = @()
	foreach ($step in $LoadBearingCiSteps) {
		$pattern = '(?m)^\s*-\s*name:\s*' + [regex]::Escape($step.Name) + '\s*$[\s\S]*?^\s*run:\s*' + [regex]::Escape($step.Run) + '\s*$'
		if ($Text -notmatch $pattern) {
			$missing += $step.Name
		}
	}
	return $missing
}

# A copy of $Text with one $LoadBearingCiSteps entry's whole step -- its
# "- name:" line through the last line before the next step -- removed. Used
# only to prove Get-MissingCiStep actually goes red on a deletion, never to
# rewrite the real ci.yml.
function Remove-CiStep {
	param(
		[Parameter(Mandatory)] [string] $Text,
		[Parameter(Mandatory)] [string] $Name
	)

	$pattern = '(?m)^[ \t]*-[ \t]*name:[ \t]*' + [regex]::Escape($Name) + '[ \t]*\r?\n(?:(?![ \t]*-[ \t]*name:)[^\r\n]*\r?\n?)*'
	return [regex]::Replace($Text, $pattern, '', 1)
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

# -Threads1 exists so CI can run the child package -- the one that owns
# process/pipe/directory lifecycle -- under ODIN_TEST_THREADS=1, closing the
# #97 defect class the default 12-thread sweep cannot see (issue #104). The
# THREADS=1 behaviour itself is proved against the real src\child, by
# reverting PR #100's teardown and watching this switch go red; what a
# fixture repository can prove is the restriction, not the concurrency
# defect it exists to surface.
#
# The child fixture needs two or more tests: core:testing clamps
# thread_count = min(thread_count, total_test_count), so a single-test
# package reports "1 thread" whether or not -define:ODIN_TEST_THREADS=1 was
# passed, and could not tell the define apart from its absence.
Test-Case 'the single-thread sweep restricts itself to the child package' {
	$repo = New-FixtureRepo 'single-thread-restriction'
	Add-FixturePackage -RepoRoot $repo -Name 'child' -Test 'passing' -PassingCount 4 | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'sibling' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' -ScriptArguments @('-Threads1')
	Assert-Result -Result $result -Matching 'All 4 tests? passed'
	Assert-Result -Result $result -Matching 'Starting test runner with 1 thread\.'
	if ($result.Output -match 'sibling') {
		throw "the sibling package ran under -Threads1, which is scoped to child alone.`n$($result.Output)"
	}
}

Test-Case 'the single-thread sweep fails loudly when the child package is missing' {
	$repo = New-FixtureRepo 'single-thread-no-child'
	Add-FixturePackage -RepoRoot $repo -Name 'sibling' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' -ScriptArguments @('-Threads1')
	Assert-Result -Result $result -Fails -Matching "no package 'child'"
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
Test-Case 'the sweep budget fits inside every CI timeout that wraps it' {
	$workflow = Join-Path $RepoRoot '.github\workflows\ci.yml'
	if (-not (Test-Path -LiteralPath $workflow)) {
		throw "no $workflow to read the job timeout out of."
	}
	# Matches, not Match: a step-level timeout-minutes wraps a test.ps1
	# invocation exactly as the job-level one does, and test.ps1 imposes the
	# same $OdinSweepTimeoutSeconds ceiling on every invocation regardless of
	# which or how many packages it runs. Reading only the first occurrence
	# left every step-level timeout unchecked.
	$declared = @([regex]::Matches((Get-Content -LiteralPath $workflow -Raw), '(?m)^\s*timeout-minutes:\s*(\d+)'))
	if ($declared.Count -eq 0) {
		throw "no timeout-minutes in $workflow, so the job falls back to the platform's six-hour default."
	}

	if ($OdinSweepTimeoutSeconds -lt $OdinCommandTimeoutSeconds) {
		throw "the sweep's $OdinSweepTimeoutSeconds-second budget is below one package's $OdinCommandTimeoutSeconds, so a single slow package is killed by the sweep rather than by its own ceiling."
	}
	foreach ($match in $declared) {
		$minutes = [int] $match.Groups[1].Value
		$seconds = $minutes * 60
		if ($OdinSweepTimeoutSeconds -ge $seconds) {
			throw "a timeout-minutes of $minutes ($seconds seconds) in $workflow does not clear the sweep's $OdinSweepTimeoutSeconds-second budget, so a hang there is reported by that timeout, which names nothing, rather than by the sweep naming the package."
		}
	}
}

# Filed from the #104 review (issue #116): this file read ci.yml at exactly
# one point -- the timeout guard above -- and pinned the existence of no step
# at all. Deleting Test, Build (debug), Check formatting or the #104
# single-thread sweep left every case in this file green, because none of
# them read what CI itself runs.
Test-Case 'ci.yml still runs every load-bearing step build.ps1 and test.ps1 own' {
	if ($LoadBearingCiSteps.Count -eq 0) {
		throw 'no load-bearing steps declared, so this case checks nothing.'
	}
	$workflow = Join-Path $RepoRoot '.github\workflows\ci.yml'
	if (-not (Test-Path -LiteralPath $workflow)) {
		throw "no $workflow to read the load-bearing steps out of."
	}
	$missing = @(Get-MissingCiStep -Text (Get-Content -LiteralPath $workflow -Raw))
	if ($missing.Count -gt 0) {
		throw "ci.yml no longer runs: $($missing -join ', ')."
	}
}

# The negative space (rule A3), proved against each step in turn rather than
# claimed: a pin that never fires on a deletion is worth exactly what the
# case above would be without it -- a check nobody has watched go red.
Test-Case 'a load-bearing ci.yml step deleted turns the pin red naming it' {
	if ($LoadBearingCiSteps.Count -eq 0) {
		throw 'no load-bearing steps declared, so this case checks nothing.'
	}
	$workflow = Join-Path $RepoRoot '.github\workflows\ci.yml'
	if (-not (Test-Path -LiteralPath $workflow)) {
		throw "no $workflow to read the load-bearing steps out of."
	}
	$text = Get-Content -LiteralPath $workflow -Raw

	foreach ($step in $LoadBearingCiSteps) {
		$mutated = Remove-CiStep -Text $text -Name $step.Name
		if ($mutated -eq $text) {
			throw "deleting the '$($step.Name)' step changed nothing, so this case removed no step at all."
		}
		$missing = @(Get-MissingCiStep -Text $mutated)
		if ($missing -notcontains $step.Name) {
			throw "deleting the '$($step.Name)' step did not turn the pin red naming it. Reported missing: $($missing -join ', ')"
		}
		# Named alone, not swept up with a sibling: deleting one step must not
		# report a step still standing in the mutated file.
		foreach ($sibling in $LoadBearingCiSteps) {
			if ($sibling.Name -eq $step.Name) {
				continue
			}
			if ($missing -contains $sibling.Name) {
				throw "deleting only '$($step.Name)' also reported '$($sibling.Name)' missing, so the deletion pattern removed more than one step."
			}
		}
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

Test-Case 'a build with nothing to read Odin with fails rather than reporting four verdicts' {
	# THE BOOTSTRAP, from the direction that matters. What reads Odin for the four
	# source policies is an Odin program, so it has to be built before it can be
	# asked about the tree that contains it -- and the state to refuse is a build
	# that reports four policy verdicts it never reached. The scan this replaced had
	# no such state; it also had no compiler.
	#
	# The fixture carries the empty tools\ every fixture carries and no policy
	# package inside it, and the child is handed an UNSET override: PowerShell
	# deletes an environment variable assigned the empty string, so this is the one
	# case that meets the bootstrap with nothing already built.
	$repo = New-FixtureRepo 'build-no-policy-tool'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1' -Environment @{ TRANSCIBR_POLICY = '' }
	Assert-Result -Result $result -Fails -Matching 'tools.policy'
	# Named for what it costs, so the refusal is not read as a missing optional.
	Assert-Result -Result $result -Fails -Matching 'pass having read nothing'
	foreach ($claimed in @('no \.odin procedure body carries a comment', 'every \.odin procedure that returns carries')) {
		if ($result.Output -match $claimed) {
			throw "the build reported a policy verdict it had no reader for.`n$($result.Output)"
		}
	}

	# The negative space (rule A3): the same fixture with the tool it is normally
	# handed builds, so what failed above is the bootstrap and not the fixture.
	$passes = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $passes -Matching 'Built 1 target'
}

Test-Case 'a source the policy tool cannot read fails the check rather than passing it' {
	# CLAUDE.md rule A8 at the seam it applies to: a source file is external input,
	# and one that is not Odin at all must be refused rather than read half way.
	# Refused whole -- a file with a fault carries no facts -- so no policy below can
	# report a clean verdict about a file nothing looked inside.
	#
	# Asked of the policy rather than of the build command, because build.ps1 runs
	# the formatting check first and odinfmt reads its input with the same parser:
	# a file this refuses is a file that never reaches here when a formatter is
	# installed.
	$repo = New-FixtureRepo 'policy-unreadable-source'
	$package = Join-Path (Join-Path $repo 'src') 'broken'
	New-Item -ItemType Directory -Path $package -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $package 'broken.odin') -Text "$FixtureVetTags`npackage broken`n`nheld :: proc( {`n"

	$refused = & {
		$RepoRoot = $repo
		try {
			Assert-OdinCommentPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($refused -eq '') {
		throw 'Assert-OdinCommentPolicy passed over a file that is not Odin, so its verdict is a claim about a file nothing read.'
	}
	foreach ($claim in @('src/broken/broken\.odin', 'Not_Odin', 'does not parse')) {
		if ($refused -notmatch $claim) {
			throw "the refusal did not name /$claim/: $refused"
		}
	}

	# The negative space (rule A3). Every line above is satisfied by a policy that
	# refuses whatever it is pointed at, so the same file with the brace it is
	# missing has to pass.
	Write-FixtureSource -Path (Join-Path $package 'broken.odin') -Text "$FixtureVetTags`npackage broken`n`nheld :: proc() {`n}`n"
	$accepted = & {
		$RepoRoot = $repo
		try {
			Assert-OdinCommentPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($accepted -ne '') {
		throw "the same file, closed, was refused: $accepted"
	}
}

Test-Case 'a source the reader does not survive is named, not counted' {
	# The depth bound is a bound on BRACKETS, and `core:odin/parser` recurses on
	# shapes that carry none. A chain of `^` in a type runs the thread off its
	# stack at about eighty of them with a counted depth of ONE, and a stack
	# overflow has no error return to catch: the tool dies where it stands.
	#
	# What must not happen is what did. The build said the tool "exited
	# -1073741571 reading 74 file(s)" and named none of them, over a file 124
	# bytes long that odinfmt formats without complaint. So the tool writes each
	# file's NAME before it reads it, and the refusal here reports the last name
	# it wrote -- the residual is a crash, but never an anonymous one.
	#
	# Asked of the policy rather than of the build command, for the reason the
	# case above is: build.ps1 checks formatting first, and this fixture has no
	# business depending on what odinfmt makes of two hundred carets.
	$repo = New-FixtureRepo 'policy-fatal-source'
	$package = Join-Path (Join-Path $repo 'src') 'deep'
	New-Item -ItemType Directory -Path $package -Force | Out-Null
	$carets = '^' * 200
	Write-FixtureSource -Path (Join-Path $package 'deep.odin') -Text "$FixtureVetTags`npackage deep`n`nheld :: proc(a: $carets`int) {`n`t_ = a`n}`n"

	$refused = & {
		$RepoRoot = $repo
		try {
			Assert-OdinCommentPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($refused -eq '') {
		throw 'the reader survived two hundred carets, so this case measures nothing at the pin it was measured against. Re-measure the shape and the count.'
	}
	foreach ($claim in @('src.deep.deep\.odin', 'policy tool')) {
		if ($refused -notmatch $claim) {
			throw "the refusal did not name /$claim/: $refused"
		}
	}
}

# Every .odin file the four source policies read, as the policy tool reads them,
# with the guard that says the reader found something.
#
# The guard is against the ATTRIBUTE COUNT and not against zero, and that count is
# taken off the LINES by a scan that knows nothing about procedures -- so it
# cannot agree with the reader by sharing its mistake. Zero is the guard for a
# reader that broke completely, and a reader that breaks completely is the one
# failure nothing needed a guard to notice. What it lets through is a reader that
# finds five procedures out of eight hundred: still non-zero, still green, and
# blind to everything it did not reach. Every `@(require_results)` in the tree
# sits above a procedure this must have found, so the two numbers have to meet,
# and neither is written down here.
#
# Here rather than in each case for the reason Get-CaseSource is a procedure:
# written out per case it is one chance per case to leave it out of the next.
function Get-CaseSourceFact {
	$sources = @(Get-CaseSource -Having 'read')
	$facts = @(Get-OdinSourceFact -Sources $sources)

	$attributable = 0
	foreach ($fact in $facts) {
		$attributable += @($fact.Procedures | Where-Object { $_.Attributable }).Count
	}

	$annotated = 0
	foreach ($source in $sources) {
		$text = [System.IO.File]::ReadAllText($source.Path)
		$annotated += ([regex]::Matches($text, '(?m)^@.*\brequire_results\b')).Count
	}

	if ($annotated -eq 0) {
		throw "no @(require_results) anywhere in $($sources.Count) file(s), so there is no independent count to check the policy tool against."
	}
	if ($attributable -lt $annotated) {
		throw "the policy tool read $attributable procedure(s) an attribute could sit on, against $annotated @(require_results) line(s) counted off the same files -- so it is not seeing every procedure an attribute was written for."
	}
	return $facts
}

Test-Case 'no procedure the four source policies cover is over the line limit' {
	# CLAUDE.md rule F1, over every file the FORMAT check covers, which is the scope
	# that moved: the audit behind this rule was scoped to src\, and then the
	# formatter was given authority over docs\reference\ as well. It reformatted the
	# spike there from 62 lines to 107 and nothing noticed, because nothing was
	# looking outside src\. The two scopes are the same scope now, by construction --
	# Get-OdinSource is what both of them ask.
	#
	# The verdict comes from Assert-OdinProcedureLength rather than from a second
	# count written out here. Spelled again, it would be the same reader reaching the
	# same answer through the same discovery -- a copy, not a cross-check.
	Assert-OdinProcedureLength

	# What the limit is measured against, so a case reporting a clean tree cannot be
	# a case that measured a handful of it. The spans themselves are pinned in
	# tools\policy's own tests, against sources built to a known length.
	$facts = @(Get-CaseSourceFact)
	$longest = 0
	foreach ($fact in $facts) {
		foreach ($procedure in $fact.Procedures) {
			if (-not $procedure.Attributable) {
				continue
			}
			$lines = $procedure.BodyEnds - $procedure.DeclaredAt + 1
			if ($lines -gt $longest) {
				$longest = $lines
			}
		}
	}
	if ($longest -lt 2) {
		throw "the longest procedure in $($facts.Count) file(s) measured $longest line(s), which is not a procedure with a body."
	}
	if ($longest -gt $OdinProcedureLineLimit) {
		throw "the longest procedure measured $longest lines against a limit of $OdinProcedureLineLimit, and Assert-OdinProcedureLength passed anyway."
	}
}

Test-Case 'a procedure over the line limit fails the build' {
	# CLAUDE.md rule F1 is "checkable by machine and has no exceptions without a
	# maintainer decision recorded at the site", and until the reader moved it was
	# checked by this suite alone -- so a procedure over the limit reached main and
	# was reported by CI rather than by the build a developer had already run. It
	# fails the BUILD now, beside the three policies it shares a reader with.
	#
	# The body is one line over on purpose: at the limit exactly it must pass, which
	# is the second half below.
	#
	# Padded with discards rather than with prints, because the second half has to
	# get past build.ps1's smoke test -- which reads the ONE line the binary is
	# supposed to write -- and rather than with comments, because section 0 bans
	# those inside a body and the case would fail on the wrong rule.
	$repo = New-FixtureRepo 'build-long-procedure'
	$over = New-FixtureLongMain -Padding ($OdinProcedureLineLimit - 2)
	Add-FixtureBinary -RepoRoot $repo -Body $over | Out-Null

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching "CLAUDE\.md rule F1's $OdinProcedureLineLimit-line limit"
	# The LINE and the NAME and the COUNT, for the reason the comment ban names a
	# line: a checker somebody has to go and search is a checker nobody runs.
	Assert-Result -Result $result -Fails -Matching "main\.odin:6 main is $($OdinProcedureLineLimit + 1) lines"

	# The negative space (rule A3), and here it is the whole measurement: a build
	# that refuses every procedure satisfies every line above. One line shorter is
	# exactly at the limit, and there it has to build and still print its banner.
	$exactly = New-FixtureLongMain -Padding ($OdinProcedureLineLimit - 3)
	if ($exactly -eq $over) {
		throw 'the control fixture is the same text as the one under test, so it measures nothing.'
	}
	Add-FixtureBinary -RepoRoot $repo -Body $exactly | Out-Null
	$passes = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $passes -Matching "no \.odin procedure is over $OdinProcedureLineLimit lines"
	Assert-Result -Result $passes -Matching 'Built 1 target'
}

Test-Case 'the line limit the build enforces is written down' {
	Assert-PolicyClaim -Enforcer 'Assert-OdinProcedureLength' -Claims @(
		'### F1. Hard limit: 70 lines per procedure'
		'Counted from the line containing `::` through the closing brace'
	)
}

Test-Case 'no procedure the four source policies cover carries a comment in its body' {
	# CLAUDE.md section 0, which until it was mechanised nothing enforced. Rule F1
	# beside it is a hard limit a machine checks on every run; the comment ban was a
	# sweep somebody performed once, and a rule enforced once is a snapshot -- the
	# next body comment lands next week and nothing says so.
	#
	# The verdict is Assert-OdinCommentPolicy's, and what earns this case its keep is
	# Get-CaseSourceFact beside it: a reader that had stopped finding procedures
	# reports no comments inside them and reads exactly as green.
	Assert-OdinCommentPolicy
	$facts = @(Get-CaseSourceFact)

	$found = 0
	foreach ($fact in $facts) {
		$found += @($fact.Comments).Count
	}
	if ($found -ne 0) {
		throw "$found comment(s) inside a procedure body, and Assert-OdinCommentPolicy passed anyway."
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
	# reading procedure ranges rather than grepping is paid to say where. Line 7 is
	# where Add-FixtureBinary's file tag and `package main` preamble put the
	# comment above.
	Assert-Result -Result $result -Fails -Matching 'main\.odin:7'
}

Test-Case 'a procedure whose body never closes at column zero fails the build' {
	# Issue #52. The scan this replaced found the header, looked for a live line
	# whose text was exactly `}`, met the next declaration first and broke out with
	# NOTHING recorded -- so the procedure was dropped, and a dropped procedure is
	# the same green as a file that never had one. `escapes` below breaks section 0
	# and rule F2 at once and was invisible to both.
	#
	# The formatter is not what stood between the tree and this shape. It does not
	# have to produce it -- it ACCEPTS it: this fixture is an odinfmt fixed point,
	# which is why the case can assert on the policy's refusal rather than on a
	# formatting one, and `odin check` exits 0 over it under the full vet set.
	$repo = New-FixtureRepo 'build-unclosed-body'
	$escaping = @(
		'import "core:fmt"'
		''
		'escapes :: proc() -> bool {'
		"`t// a comment inside a procedure body, which section 0 bans"
		"`treturn true}"
		''
		'main :: proc() {'
		"`tfmt.println(escapes())"
		'}'
	) -join "`n"
	Add-FixtureBinary -RepoRoot $repo -Body "$escaping`n" | Out-Null

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'inside a procedure body'
	# The LINE and the PROCEDURE, which is the whole of what was dropped. Line 7 is
	# where Add-FixtureBinary's file tag, `package main` preamble and the import
	# above put the comment.
	Assert-Result -Result $result -Fails -Matching 'main\.odin:7 in escapes'
	# It must not have been read as a formatting failure instead: the file is a
	# fixed point, and a case that passed because odinfmt rewrote it would say
	# nothing about the drop.
	if ($result.Output -match 'not formatted as odinfmt') {
		throw "the fixture failed the formatting check, so this case says nothing about the procedure being dropped.`n$($result.Output)"
	}
}

Test-Case 'the comment ban the build enforces is written down' {
	Assert-PolicyClaim -Enforcer 'Assert-OdinCommentPolicy' -Claims @(
		'## 0. Comment policy'
		'Comments are banned inside procedure bodies.'
	)
}

Test-Case 'no procedure the four source policies cover hands back an unrequired answer' {
	# CLAUDE.md rule F2, over the same scope rule F1 and section 0 read, and here
	# for the direction `@(require_results)` cannot cover on its own: the attribute
	# fails a call site that DROPS an answer, and the compiler refuses it on a
	# procedure with no results -- so the procedure declared tomorrow that returns
	# a fault and never carries it is a rule nothing checks. That is the direction
	# every bare one here arrived from (issue #43).
	#
	# The verdict is Assert-OdinResultPolicy's rather than a second walk written out
	# here, and the vacuous-pass guard is Get-CaseSourceFact's: the policy runs
	# against whatever repository it is pointed at, and a program whose every
	# procedure returns nothing is ordinary -- every build fixture below is one.
	Assert-OdinResultPolicy
	$facts = @(Get-CaseSourceFact)

	$returning = 0
	$bare = @()
	foreach ($fact in $facts) {
		foreach ($procedure in $fact.Procedures) {
			if (-not $procedure.Attributable) {
				continue
			}
			if (-not $procedure.Returns) {
				continue
			}
			$returning += 1
			if (-not $procedure.Annotated) {
				$bare += "  - $($fact.Name):$($procedure.DeclaredAt) $($procedure.Name)"
			}
		}
	}
	if ($bare.Count -gt 0) {
		throw "$($bare.Count) procedure(s) return without @(require_results), and Assert-OdinResultPolicy passed anyway:`n$($bare -join "`n")"
	}
	if ($returning -eq 0) {
		throw "read no returning procedure at all out of $($facts.Count) file(s), so rule F2 measured nothing here."
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
	# runs. Line 6 is where Add-FixtureBinary's file tag and `package main`
	# preamble and the import above put the declaration.
	Assert-Result -Result $result -Fails -Matching 'main\.odin:6 banner'
}

Test-Case 'a procedure declared indented is measured rather than refused' {
	# Issue #53's first row, and the case that used to say the opposite. Rule F2's
	# verdict is a claim about EVERY procedure in the tree, and a procedure declared
	# inside a `when` block is one no column-zero scan could see -- so the scan this
	# replaced was kept honest by a guard that REFUSED the declaration outright,
	# which is a rule about where code may be written rather than about what it may
	# say.
	#
	# The parser has no column to be anchored to. So the same fixture that used to
	# be refused for being invisible is now read, and refused for the reason it
	# actually deserves: it returns and carries no attribute.
	$repo = New-FixtureRepo 'result-policy-indented'
	$package = Join-Path (Join-Path $repo 'src') 'hidden'
	New-Item -ItemType Directory -Path $package -Force | Out-Null
	$indented = @(
		$FixtureVetTags
		'package hidden'
		''
		'when ODIN_OS == .Windows {'
		"`thelper :: proc() -> bool {"
		"`t`treturn true"
		"`t}"
		'}'
	) -join "`n"
	Write-FixtureSource -Path (Join-Path $package 'hidden.odin') -Text "$indented`n"

	# The policy takes no arguments and reads the tree through Get-OdinSource, so
	# the root it reads is the seam. Rebound in a scope of its own rather than over
	# this case, and it fails SAFE: a rebinding that stopped reaching the function
	# would point it at the real repository, which carries no bare returning
	# procedure, and this case would fail rather than quietly pass.
	$refused = & {
		$RepoRoot = $repo
		try {
			Assert-OdinResultPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($refused -eq '') {
		throw 'Assert-OdinResultPolicy accepted a repository whose only returning procedure is declared indented and carries no attribute, so it is not reading one at all.'
	}
	foreach ($claim in @('CLAUDE\.md rule F2', 'src/hidden/hidden\.odin:5 helper')) {
		if ($refused -notmatch $claim) {
			throw "the refusal did not name /$claim/: $refused"
		}
	}

	# The negative space (rule A3). Every line above is satisfied by a policy that
	# refuses whatever it is pointed at, so the same procedure is checked WITH the
	# attribute -- same indentation, same body, one line of difference -- and there
	# it has to pass. This is the half the guard could never reach: an indented
	# procedure used to fail the build however it was written.
	$annotated = @(
		$FixtureVetTags
		'package hidden'
		''
		'when ODIN_OS == .Windows {'
		"`t@(require_results)"
		"`thelper :: proc() -> bool {"
		"`t`treturn true"
		"`t}"
		'}'
	) -join "`n"
	Write-FixtureSource -Path (Join-Path $package 'hidden.odin') -Text "$annotated`n"
	$accepted = & {
		$RepoRoot = $repo
		try {
			Assert-OdinResultPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($accepted -ne '') {
		throw "the same indented procedure, carrying the attribute, was refused: $accepted"
	}
}

Test-Case 'a procedure TYPE above a table builds, because nothing can annotate one' {
	# The other direction of the case above, at the level that matters: a false
	# positive here is not a wrong message, it is a repository that cannot be
	# built. The attribute rule F2 would demand is one the compiler refuses on a
	# procedure type -- `Unknown attribute element name 'require_results'` -- so
	# there is no edit to the source that makes such a build pass.
	#
	# The fixture is issue #36's shared fault report in miniature, and the shape
	# src\process\command_line.odin and src\transcript\engine_json.odin already
	# carry: a fault-facts signature above a `:=` table. What kept those two from
	# tripping it was the `@(private, rodata)` above their tables, which the old
	# scan stopped at by luck rather than by rule -- so the table here carries no
	# attribute, which is the shape that actually failed.
	$repo = New-FixtureRepo 'build-procedure-type'
	$shape = @(
		'import "core:fmt"'
		''
		'@(private)'
		'Probe_Fault :: enum u8 {'
		"`tNone = 0,"
		"`tBroken,"
		'}'
		''
		'@(private)'
		'Probe_Says :: proc(fault: Probe_Fault) -> string'
		''
		'PROBE := [Probe_Fault]string {'
		"`t.None   = `"`","
		"`t.Broken = `"broken`","
		'}'
		''
		'main :: proc() {'
		"`t_ = PROBE[.Broken]"
		"`tfmt.println(`"$SmokeBanner`")"
		'}'
	) -join "`n"
	Add-FixtureBinary -RepoRoot $repo -Body "$shape`n" | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Matching 'every \.odin procedure that returns carries'
}

Test-Case 'the result rule the build enforces is written down' {
	# The discard spelling is pinned twice over, because the attribute changes what
	# a `defer` has to look like and nothing else in the tree would say so: no site
	# hits it today, so the first person to write `defer f()` over an annotated
	# procedure meets a compiler error with no rule behind it.
	Assert-PolicyClaim -Enforcer 'Assert-OdinResultPolicy' -Claims @(
		'### F2. `@(require_results)` on every procedure that returns anything'
		'spells it `_ = f(...)`'
		'`defer _ = f()`'
	)
}

Test-Case 'every .odin file the checks cover declares the vet tags' {
	# CLAUDE.md rule M2, over the same scope rule F1, section 0 and rule F2 read.
	# The tag is what turns ADR-0010 from a review finding into a compile error,
	# and it is PER FILE -- measured: a package with one tagged file and one
	# untagged sibling builds clean, with the sibling's implicit allocators
	# unchecked. So a file that never gets the tag is not a rule broken loudly, it
	# is a file nothing checks.
	#
	# The verdict itself comes from Assert-OdinVetTagPolicy rather than from a
	# second walk written out here. Spelled again, it would be the same reader
	# reaching the same answer through the same discovery -- a copy, not a
	# cross-check, and one that goes on passing while the real policy drifts.
	Assert-OdinVetTagPolicy

	# What earns this case its keep is the count beside it, taken off the LINES by
	# a scan that knows nothing about package clauses, comments or scopes -- so it
	# cannot agree with the reader by sharing its mistake. Rule F2's case above is
	# built the same way, against its attribute count.
	#
	# A reader that credited a name in everything it was shown satisfies the policy
	# over a tree with no tags in it at all; this is what says the lines are really
	# there. The other direction -- a reader that finds one nowhere -- fails the
	# policy already and needs nothing here.
	$sources = @(Get-CaseSource -Having 'read')
	$declaring = 0
	foreach ($source in $sources) {
		if ([System.IO.File]::ReadAllText($source.Path) -match '(?m)^#\+vet\b') {
			$declaring += 1
		}
	}
	if ($declaring -ne $sources.Count) {
		throw "the policy passed over $($sources.Count) file(s), but only $declaring of them carry a '#+vet' line at all -- so it is reading names into files that do not have them."
	}

	# And that the policy DEMANDED something, which is the seam the compiler case
	# below covers from the other end. $OdinFileVetTags emptied leaves
	# Assert-OdinVetTagPolicy finding nothing missing because nothing is asked for,
	# over a tree that still carries every tag -- green, and measuring nothing.
	$asked = @(Get-OdinRequiredVetTag -Name $sources[0].Name)
	if ($asked.Count -eq 0) {
		throw "the policy passed while requiring no name at all of $($sources[0].Name), so it would pass over a tree with no tags in it."
	}
}

Test-Case 'a file without the vet tag fails the build' {
	# The whole reason the tag is checked at all rather than merely written once.
	# It is PER FILE -- measured: a package holding one tagged file and one
	# untagged sibling builds clean, and the sibling's implicit allocators are
	# never looked at. So a file that arrives without it does not break a rule
	# loudly, it quietly leaves itself out of one, which is the same failure
	# $OdinPackagesWithoutTests and the format sweep's zero-file rule are here for.
	#
	# The fixture is the file every passing case plants, minus its tag: the one
	# difference between them is the thing under test.
	$repo = New-FixtureRepo 'build-untagged'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null
	$stripped = Join-Path (Add-FixturePackage -RepoRoot $repo -Name 'untagged' -Test 'none') 'untagged.odin'
	$text = [System.IO.File]::ReadAllText($stripped)
	Write-FixtureSource -Path $stripped -Text ($text -replace '(?m)^#\+vet[^\r\n]*\r?\n', '')

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'CLAUDE\.md rule M2'
	# The FILE and the NAME it is missing, for the reason the comment ban names a
	# line: a checker somebody has to go and search is a checker nobody runs. The
	# binary beside it still carries the tag, so naming the wrong file would be a
	# refusal pointing at a file that is already right.
	Assert-Result -Result $result -Fails -Matching 'src/untagged/untagged\.odin'
	Assert-Result -Result $result -Fails -Matching 'explicit-allocators'
	if ($result.Output -match 'src/cli/main\.odin') {
		throw "the refusal named the tagged binary as well.`n$($result.Output)"
	}
}

Test-Case 'a vet name in the wrong case is not the name the compiler reads' {
	# The policy matches `#+vet` names case-SENSITIVELY, the way the compiler
	# matches them: `EXPLICIT-ALLOCATORS` is not a spelling of
	# `explicit-allocators`, it is `Syntax Error: Invalid vet flag name`. A reader
	# that accepted it would credit a file with a check that is not on, which is
	# rule M2's whole subject -- a file quietly leaving itself out of one.
	#
	# Measured: softening `-cnotcontains` to `-notcontains` in
	# Assert-OdinVetTagPolicy left every other case in this suite green and the
	# build green, so nothing but this stands under that one letter.
	#
	# Asked of the policy rather than of the build command because the compiler
	# refuses the misspelling on its own moments later: a build fixture goes red
	# either way and says nothing about which of the two refused it.
	$repo = New-FixtureRepo 'policy-miscased-tag'
	$package = Join-Path (Join-Path $repo 'src') 'shouty'
	New-Item -ItemType Directory -Path $package -Force | Out-Null
	$required = @(Get-OdinRequiredVetTag -Name 'src/shouty/shouty.odin')
	$shouted = "#+vet $(($required | ForEach-Object { $_.ToUpperInvariant() }) -join ' ')"
	Write-FixtureSource -Path (Join-Path $package 'shouty.odin') -Text "$shouted`npackage shouty`n`nheld :: proc() {`n}`n"

	$refused = & {
		$RepoRoot = $repo
		try {
			Assert-OdinVetTagPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($refused -eq '') {
		throw "the policy read '$shouted' as declaring $($required -join ' '), so it accepts a spelling the compiler refuses."
	}
	foreach ($claim in @('src.shouty.shouty\.odin', [regex]::Escape($required[0]))) {
		if ($refused -cnotmatch $claim) {
			throw "the refusal did not name /$claim/: $refused"
		}
	}

	# The negative space (rule A3): the same file with the name spelled as the
	# compiler spells it passes, so what failed above is the casing and not the
	# fixture.
	Write-FixtureSource -Path (Join-Path $package 'shouty.odin') -Text "$FixtureVetTags`npackage shouty`n`nheld :: proc() {`n}`n"
	$accepted = & {
		$RepoRoot = $repo
		try {
			Assert-OdinVetTagPolicy
			''
		}
		catch {
			$_.Exception.Message
		}
	}
	if ($accepted -ne '') {
		throw "the same file, spelled as the compiler spells it, was refused: $accepted"
	}
}

Test-Case 'a call that takes its allocator from the context fails the build' {
	# The deliverable, end to end, and the one claim none of the cases above make.
	# They check that the tag is WRITTEN -- and a tag that is written on every file
	# and does nothing reads exactly the same green. What is between those two is
	# the compiler, so the only way to tell them apart is to hand it a call that
	# must not compile and watch it refuse.
	#
	# That is not a hypothetical seam. $OdinFileVetTags emptied leaves every case
	# above passing vacuously, and a compiler pin that moved the flag's name or its
	# behaviour would be reported by nothing else here.
	#
	# The fixture is the binary every other build case uses, one argument short:
	# it prints the same banner and exits zero, so what fails is the allocator and
	# nothing the compiler would have caught anyway.
	$repo = New-FixtureRepo 'build-implicit-allocator'
	$implicit = @(
		'import "core:fmt"'
		'import "core:strings"'
		''
		'main :: proc() {'
		"`tsaid := strings.clone(`"$SmokeBanner`")"
		"`tdefer delete(said, context.allocator)"
		"`tfmt.println(said)"
		'}'
	) -join "`n"
	Add-FixtureBinary -RepoRoot $repo -Body "$implicit`n" | Out-Null

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching "Parameter 'allocator' of type 'Allocator' must be explicitly provided"
	# The LINE, so this cannot be satisfied by a build that failed somewhere else.
	# Line 8 is where Add-FixtureBinary's file tag, `package main` preamble and the
	# two imports put the clone.
	Assert-Result -Result $result -Fails -Matching 'main\.odin\(8:'

	# The negative space (rule A3), and here it is the whole measurement rather
	# than a formality: a build that refuses everything satisfies every line above.
	# Same file, same banner, one argument of difference.
	$explicit = $implicit.Replace("strings.clone(`"$SmokeBanner`")", "strings.clone(`"$SmokeBanner`", context.allocator)")
	if ($explicit -eq $implicit) {
		throw 'the control fixture is the same text as the one under test, so it measures nothing.'
	}
	Add-FixtureBinary -RepoRoot $repo -Body "$explicit`n" | Out-Null
	$passes = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $passes -Matching 'Built 1 target'
}

Test-Case 'a +vet name that turns a check off fails the build if it is declared for every file' {
	# The trap the next ticket walks into. Issue #45's job is to add
	# `!unused-procedures`, which is an EXEMPTION -- wanted on `_test.odin` and
	# nowhere else, because `@(test)` reads as unused in both build and test mode.
	# Written as one more entry covering every file, it turns
	# -vet-unused-procedures OFF across every production file in the repository:
	# measured, a file carrying a dead procedure goes from
	# `'dead_helper' declared but not used` and exit 1 to exit 0 saying nothing.
	#
	# That is the same silence rule M2 exists for, arriving through the declaration
	# rather than through a file. So a name that turns a check off may not be
	# declared at repository scope, and this is the case that makes typing it a
	# failed build rather than a quiet one.
	$repo = New-FixtureRepo 'build-disabling-tag'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	# Patched into the fixture's own copy of common.ps1, so what is under test is
	# the edit itself and not a description of one.
	$common = Join-Path (Join-Path $repo 'scripts') 'common.ps1'
	$text = [System.IO.File]::ReadAllText($common)
	$eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
	$opening = '$OdinFileVetTags = @('
	$shortcut = $text.Replace($opening, "$opening$eol`t[pscustomobject]@{ Name = '!unused-procedures'; Scope = 'Every' }")
	if ($shortcut -eq $text) {
		throw "the fixture's common.ps1 does not open the declaration with ``$opening``, so this case patched nothing."
	}
	[System.IO.File]::WriteAllText($common, $shortcut, $Utf8NoBom)

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching '!unused-procedures'
	Assert-Result -Result $result -Fails -Matching 'turns a check off'
	# Refused for what the DECLARATION says, not for the files disagreeing with it.
	# Every fixture source was written before the patch, so the per-file check would
	# also fail here -- and passing on that would leave #45 free to add the name and
	# write it into every file, which is the whole defect.
	if ($result.Output -match 'does not declare') {
		throw "the build refused the FILES for not carrying the name, so declaring it is still the cheaper way out.`n$($result.Output)"
	}

	# The negative space (rule A3): the refusal above is satisfied by a resolver
	# that refuses everything, so the real declaration goes through the same one.
	$required = @(Get-OdinRequiredVetTag -Name 'src/version/version.odin')
	if ($required -cnotcontains 'explicit-allocators') {
		throw "the real declaration required $($required.Count) name(s) of a production file, none of them explicit-allocators: $($required -join ', ')"
	}
}

Test-Case 'a +vet name scoped to files nothing resolves is refused where it is written' {
	# The other silent direction out of the same seam, and load-bearing for the same
	# ticket. A scope the resolver has no arm for is a name required of NO file:
	# green build, check covering nothing, and no diagnostic anywhere -- the failure
	# rule M2 is here for, arriving through the declaration instead of through a
	# file. So issue #45 adding a scope has to teach the resolver about it, and
	# writing one it does not know fails rather than resolving to nothing.
	$refused = ''
	try {
		Get-OdinRequiredVetTag -Name 'src/version/version.odin' `
			-Tags @([pscustomobject]@{ Name = 'explicit-allocators'; Scope = 'Some-Files' }) | Out-Null
	} catch {
		$refused = "$_"
	}
	if ($refused -notmatch 'Some-Files') {
		throw "an unknown scope resolved to something rather than being refused: '$refused'"
	}

	# The negative space (rule A3). The line above is satisfied by a resolver that
	# refuses every scope, so the same name at the scope this repository does know
	# is asked for beside it.
	$known = @(Get-OdinRequiredVetTag -Name 'src/version/version.odin' `
			-Tags @([pscustomobject]@{ Name = 'explicit-allocators'; Scope = 'Every' }))
	if (($known.Count -ne 1) -or ($known[0] -ne 'explicit-allocators')) {
		throw "a name at the one scope there is resolved to: $($known.Count) name(s) $($known -join ', ')"
	}
}

Test-Case 'the vet tag rule the build enforces is written down' {
	# A tag on 65 files is the version of the defect above with the most lines to
	# delete. Three things are pinned beyond the heading.
	#
	# The per-file reading, because it is the whole argument for checking the tag
	# rather than writing it once: without it the check reads as belt and braces
	# over a compiler that already refuses.
	#
	# The resolver by name, because the two refusals it carries are the rule as much
	# as the tag is -- a name that turns a check off, and a scope nothing resolves.
	#
	# And the NAMES, taken from the declaration rather than spelled again, so a name
	# added to $OdinFileVetTags is a name CLAUDE.md has to explain before the build
	# will pass.
	#
	# The heading states the property and not a habit. It used to say "on the first
	# line of every file", which nothing checks and which issue #48 makes false for
	# half the tree the day `#+private` goes above these tags. A pinned sentence that
	# a later ticket has to edit a test case to repair is a pin that will be deleted
	# rather than corrected.
	Assert-PolicyClaim -Enforcer 'Assert-OdinVetTagPolicy' -Claims (@(
			'### M2. Every file declares the repository''s `#+vet` names above its `package` clause'
			'per file'
			'Get-OdinRequiredVetTag'
		) + @($OdinFileVetTags | ForEach-Object { $_.Name }))
}

# ------------------------------------------------ cases for the remove_all gate --
#
# Issue #105: no `os.remove_all(...)` call expression anywhere in the tree.
# tools\policy's own remove_all_test.odin already proves the Odin-side reader
# finds and skips the right lines; nothing before this pinned the OTHER half of
# the check -- Read-OdinPolicyReport's 'remove_all' record arm and
# Assert-OdinRemoveAllPolicy reading it -- so a PowerShell-side regression there
# had nothing to fail against. Measured: discarding the 'remove_all' record
# instead of collecting it left build.ps1, the full test sweep and every prior
# selftest case green, with the tool's answer read and silently thrown away.
# These two cases are what a fixture build going red over a planted call, and
# passing clean without one, actually proves against that regression.
Test-Case 'a stray os.remove_all call fails the build' {
	$repo = New-FixtureRepo 'build-stray-remove-all'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	$dir = Join-Path (Join-Path $repo 'src') 'purge'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'purge.odin') -Text (
		"$FixtureVetTags`npackage purge`n`nimport `"core:os`"`n`n" +
		"held :: proc() {`n`t_ = os.remove_all(`"x`")`n}`n"
	)

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching 'os\.remove_all\(\.\.\.\) call'
	# The FILE and LINE, for the reason every other checker here names one: a
	# refusal somebody has to go and search the tree for is a refusal nobody
	# actually reads.
	Assert-Result -Result $result -Fails -Matching 'src/purge/purge\.odin:7'
}

Test-Case 'a comment naming os.remove_all does not fail the build' {
	# The negative space (rule A3): a check that refused every file mentioning
	# the name in prose, rather than calling it, would pass the case above for
	# the wrong reason. directory_test.odin carries exactly this shape today
	# and has to keep passing.
	$repo = New-FixtureRepo 'build-remove-all-comment'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	$dir = Join-Path (Join-Path $repo 'src') 'purge'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'purge.odin') -Text (
		"$FixtureVetTags`npackage purge`n`n// never call os.remove_all here`n" +
		"held :: proc() {`n`treturn`n}`n"
	)

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Matching 'no \.odin file calls os\.remove_all'
	Assert-Result -Result $result -Matching 'Built 1 target'
}

Test-Case 'the remove_all ban is written down' {
	# Sixth caller of Assert-PolicyClaim, and the one Assert-OdinRemoveAllPolicy
	# was missing: the other five build-failing enforcers (procedure length,
	# comment ban, result policy, vet tags, network confinement) all pin a
	# claim in the document that states the rule they enforce. This one had no
	# document at all -- a scan replicating Assert-PolicyClaim's own Contains
	# check, run over CLAUDE.md, README.md, CONTEXT.md and every file under
	# docs\, found zero hits for 'remove_all', 'Assert-OdinRemoveAllPolicy' or
	# '#105' anywhere in the tree. A contributor who trips the gate had a good
	# error message and nothing to read.
	Assert-PolicyClaim -Enforcer 'Assert-OdinRemoveAllPolicy' -Claims @(
		'No `os.remove_all(...)` call anywhere in the tree (issue #97/#105)'
		'Assert-OdinRemoveAllPolicy'
	)
}

# ------------------------------------------------- cases for the network gate --
#
# README.md's Network access section (issue #58): all network code lives in
# one file, src/net/winhttp.odin, and the build fails the moment the name
# appears, in any case, anywhere else under src\. Nothing checked that until
# now -- src/net does not exist yet, so today's tree passes vacuously, and
# the cases below are what stand between that and the claim quietly going
# false: the day issue #14 lands a second file that mentions the name, the
# day somebody spells it in a different case, and the day a caller hands the
# check a source list with nothing under src\ at all.

# The path split once, rather than four fixture bodies each spelling
# 'src', 'net' and 'winhttp.odin' as their own literals: if issue #14 ever
# names the real file something else, these cases move with it instead of
# quietly testing a path nothing checks any more.
$NetworkFixtureRelativePath = $OdinNetworkCodeRelativeName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
$NetworkFixtureMatchPath = [regex]::Escape($OdinNetworkCodeRelativeName)

Test-Case 'the word winhttp outside its one allowed file fails the build' {
	$repo = New-FixtureRepo 'build-stray-winhttp'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	# Anywhere but src/net/winhttp.odin is the claim's whole subject, so this
	# plants the name in an unrelated package rather than in a plausible-looking
	# rival of the real one.
	$dir = Join-Path (Join-Path $repo 'src') 'other'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'other.odin') -Text "$FixtureVetTags`npackage other`n`nSTRAY :: `"winhttp`"`n"

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching "'winhttp' appears outside $NetworkFixtureMatchPath"
	# The FILE and not merely the count, for the reason every other checker here
	# names one: a claim somebody has to go and search the tree for is a claim
	# nobody checks by hand either.
	Assert-Result -Result $result -Fails -Matching 'src/other/other\.odin'
}

Test-Case 'the canonical Win32 spelling outside its one allowed file fails the build' {
	# Finding from an adversarial review of this gate (issue #58): planting
	# `WinHttpOpen` -- the Win32 headers' own capitalisation, not the all-
	# lowercase spelling nobody writes -- passed build.ps1 while the match
	# was ordinal case-sensitive. This is the case that goes green again if
	# the comparison reverts to a plain `.Contains` with no comparer.
	$repo = New-FixtureRepo 'build-real-spelling-winhttp'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	$dir = Join-Path (Join-Path $repo 'src') 'probe'
	New-Item -ItemType Directory -Path $dir -Force | Out-Null
	Write-FixtureSource -Path (Join-Path $dir 'probe.odin') -Text "$FixtureVetTags`npackage probe`n`nENTRY_POINT :: `"WinHttpOpen`"`n"

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Fails -Matching "'winhttp' appears outside $NetworkFixtureMatchPath"
	Assert-Result -Result $result -Fails -Matching 'src/probe/probe\.odin'
}

Test-Case 'the word winhttp inside its one allowed file does not fail the build' {
	# The negative space (rule A3): a check that refused every file containing
	# the name would pass the case above for the wrong reason. This is the one
	# place the name is allowed, and a build naming it there still has to finish.
	$repo = New-FixtureRepo 'build-allowed-winhttp'
	Add-FixtureBinary -RepoRoot $repo -Body (New-FixtureMain -Line $SmokeBanner) | Out-Null

	$fixturePath = Join-Path $repo $NetworkFixtureRelativePath
	New-Item -ItemType Directory -Path (Split-Path -Parent $fixturePath) -Force | Out-Null
	Write-FixtureSource -Path $fixturePath -Text "$FixtureVetTags`npackage net`n`nWINHTTP :: `"WinHttpOpen`"`n"

	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'build.ps1'
	Assert-Result -Result $result -Matching "is confined to $NetworkFixtureMatchPath"
	Assert-Result -Result $result -Matching 'Built 1 target'
}

Test-Case 'network confinement over a source list with nothing under src refuses to pass' {
	# Sibling defect to Assert-OdinProcedureLength's own "measured nothing"
	# guard (common.ps1, rule F1): Get-OdinCheckedSource refuses an empty list
	# repository-wide, but nothing guarded the src\-filtered subset the network
	# confinement claim is actually about, so a $Sources list holding real
	# files -- none of them under src\ -- reported the same green as a real
	# sweep. In-process rather than through a fixture build: no ordinary
	# checkout can produce a src\ with no .odin files in it at all, so the
	# only way to exercise this is to hand the function a source list a real
	# discovery would never produce, the way Get-OdinRequiredVetTag's own
	# cases hand it a fabricated $Tags.
	$outsideSrc = @([pscustomobject]@{
			Path = Join-Path $OdinPolicyPackage 'policy.odin'
			Name = 'tools/policy/policy.odin'
		})
	$refused = ''
	try {
		Assert-OdinNetworkConfinement -Sources $outsideSrc
	} catch {
		$refused = "$_"
	}
	if ($refused -notmatch 'under src\\') {
		throw "a source list with nothing under src\ did not refuse: '$refused'"
	}
}

Test-Case 'the network confinement claim README makes is written down' {
	# The 'grep -ri --include=*.odin -r winhttp src/' claim used to be pinned
	# verbatim; narrowed to the bare 'is the whole audit' the day README's
	# audit command grew '-i' and '--include=*.odin' and nobody re-pinned the
	# new wording, this case passed a README reverted to the case-SENSITIVE
	# `grep -r winhttp src/` -- the exact command whose case-blindness was the
	# defect Assert-OdinNetworkConfinement exists to close. The '-i' below is
	# the token that regression needs pinned; 'is the whole audit' alone does
	# not see it move.
	Assert-PolicyClaim -Document 'README.md' -Enforcer 'Assert-OdinNetworkConfinement' -Claims @(
		'grep -ri --include=*.odin -r winhttp src/` is the whole audit'
		'Assert-OdinNetworkConfinement'
	)
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
