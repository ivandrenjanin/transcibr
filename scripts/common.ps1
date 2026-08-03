# Everything build.ps1, test.ps1, selftest.ps1 and .github/workflows/ci.yml
# share, dot-sourced by all four.
#
# Two halves, and they are here for one reason: all three commands need them and
# none of them may answer differently. The DECLARATIONS -- the vet set, the
# compiler pin, the list of binaries, the list of packages expected to hold no
# tests, the ceilings -- live here once, because held separately they drift and
# code that compiles under one command starts failing under the other. The
# PROCESS PLUMBING below them knows nothing about Odin: how to escape an argument
# for a Windows command line, how to start a child and read what it printed, and
# how to stop waiting for one that is never coming back.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Normalised through GetFullPath so every path exported here is spelled the one
# way. A label computed by trimming $SrcRoot off a discovered path is only
# correct while the two agree on separators and casing.
$RepoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'src'))
$BuildRoot = Join-Path $RepoRoot 'build'

# The full vet set from CLAUDE.md rule S1. Every build and test invocation
# passes all of it, warnings included. This array is the only copy; the
# documentation points here rather than repeating the flags.
$OdinVetFlags = @(
	'-vet'
	'-vet-tabs'
	'-strict-style'
	'-vet-style'
	'-warnings-as-errors'
	'-disallow-do'
)

# Packages import each other as `transcibr:<package>`.
$OdinCollection = "-collection:transcibr=$SrcRoot"

# The wall-clock ceiling on ONE child process this repository starts, in seconds.
#
# Nothing in the toolchain has one of its own. `odin test` builds a test
# executable and then RUNS it, and that runner hangs outright when two or more
# tests assert concurrently -- the mechanism is written out once, in CLAUDE.md's
# Odin notes, and the cases that pin it are in scripts\selftest.ps1. Assertions
# are the failure mode this repository's whole design rests on (CLAUDE.md section
# 1), so a sweep that waits forever for one is a developer's terminal that never
# comes back and a CI job that burns the platform's six-hour default before
# saying anything.
#
# Ten minutes, not one: this repository's whole sweep takes seconds, but a cold
# CI runner compiling from an empty cache is exactly the run that must not be
# killed for being slow. The ceiling exists to bound a HANG, not to police speed.
# build.ps1's smoke test runs under it as well: a binary that should answer in
# milliseconds needs no knob of its own, and a knob nobody would ever tune is a
# knob that goes stale. scripts\selftest.ps1 passes its own, far shorter, because
# it plants packages built to hang and cannot wait ten minutes to find out that
# they did.
$OdinCommandTimeoutSeconds = 600

# The wall-clock ceiling on a WHOLE test sweep, in seconds, whatever it finds
# under src\.
#
# The ceiling above bounds one package. Without this one the sweep's worst case
# is that number times however many packages exist, and nothing states the
# relationship: at the three packages here it is already the CI job's entire
# 30-minute budget (.github/workflows/ci.yml), and a fourth crosses it. Past that
# line a sweep where several packages hang is reported by GitHub's job timeout,
# which names nothing and produces no output, rather than by the sweep naming the
# package that wedged. Fifteen minutes keeps the toolchain download and both
# builds inside the job's budget alongside it.
$OdinSweepTimeoutSeconds = 900

# How long a killed process tree is given to actually die, in seconds, before its
# exit code is written off as unreadable. Best effort by nature: taskkill has
# already been asked, and what is being waited for is the OS getting round to it.
$ProcessKillGraceSeconds = 30

# The compiler this repository is pinned to, in its two spellings: the release
# tag CI downloads, and the string that release's `odin version` prints. They
# do not resemble each other and there is no deriving one from the other, so
# both live here and CI dot-sources this file for the tag rather than keeping
# a second copy in the workflow. One edit moves the pin.
$OdinReleaseTag = 'dev-2026-07a'
$OdinVersionPin = 'dev-2026-07-nightly:819fdc7'

# The formatter CLAUDE.md rule S1 names, pinned the way the compiler above is --
# and pinned by CONTENT, because it is the only thing this binary can be asked.
#
# odinfmt ships in the ols release zip rather than with the Odin distribution,
# so the tag is ols's and not the compiler's. `-h` prints a usage block and
# nothing else: there is no -version flag, no banner, and no build stamp to
# read, so Confirm-OdinVersion's trick of running it and reading what it says
# has no equivalent here. What is left is the file's SHA-256, which is a
# stronger claim than a version string anyway -- it pins the exact build rather
# than a name several builds can share.
#
# The asset is resolved by pattern rather than by name inside the zip: the
# member is `odinfmt-x86_64-pc-windows-msvc.exe`, and .github/workflows/ci.yml
# globs for it exactly as it globs for odin.exe, so the layout inside the
# archive is not a second thing to keep in step.
$OdinfmtReleaseTag = 'dev-2026-06'
$OdinfmtAsset = 'ols-x86_64-pc-windows-msvc.zip'
$OdinfmtSha256 = '130742513F9F6029E7D3CF8705A1303CEF5B9B5126FA5FA030587662B83E3B9F'

# The style itself lives in odinfmt.json at the repository root, because that is
# the name odinfmt looks for and an editor's format-on-save has to find the same
# answer this build does. It is read from $RepoRoot rather than from the working
# directory so a developer running the scripts from anywhere gets the repository's
# config and not whatever sits above their shell.
$OdinFormatConfig = Join-Path $RepoRoot 'odinfmt.json'

# odinfmt's printer.Config: every key it reads, and the type it reads it as.
# `int` and `bool` mean themselves; anything else is the pipe-joined list of
# names an enum field accepts.
#
# Read out of the pinned binary rather than off a web page or a memory. Odin's
# runtime type information carries the field names of every type a program
# reflects over, and printer.Config's fifteen sit contiguously inside
# odinfmt.exe, in this order, alongside Brace_Style's four members and
# Newline_Style's two.
#
# CHECKED against it, on every run, and not merely read out of it once: the case
# "the config schema is the key set inside the pinned odinfmt" in
# scripts\selftest.ps1 searches $OdinfmtSha256's binary for these names as one
# NUL-separated run, and fails on a rename, a reorder, a removal, a key inserted
# mid-struct, or a sixteenth key appended after the last. That is what couples
# this list to the pin above: the two are separate declarations that a single
# case refuses to let disagree, so moving the pin without revisiting this list
# fails CI rather than passing quietly.
#
# The coupling is what makes the check worth anything. An unlisted key is the
# harmful direction -- odinfmt fills it from its own default in silence while
# Confirm-OdinFormatConfig below passes, because that procedure compares
# odinfmt.json against THIS LIST and both are files in this repository. Drop a
# key from both and format.ps1 exits 0 having noticed nothing; the binary is the
# only party to the question with a vote.
$OdinFormatConfigSchema = [ordered]@{
	character_width          = 'int'
	spaces                   = 'int'
	newline_limit            = 'int'
	tabs                     = 'bool'
	tabs_width               = 'int'
	convert_do               = 'bool'
	brace_style              = '_1TBS|Allman|Stroustrup|K_And_R'
	indent_cases             = 'bool'
	newline_style            = 'CRLF|LF'
	sort_imports             = 'bool'
	inline_single_stmt_case  = 'bool'
	spaces_around_colons     = 'bool'
	space_single_line_blocks = 'bool'
	align_struct_fields      = 'bool'
	align_struct_values      = 'bool'
}

# Directories the formatting sweep does not walk, as absolute paths ending in a
# separator, which is the form Get-OdinSource compares against. A deny list of
# DIRECTORIES, never a list of files: the files are discovered (Get-OdinSource),
# which is the whole point -- a hand-maintained file list stops covering the file
# somebody adds tomorrow, and nothing says so.
#
# Each entry holds no authored Odin by construction: git's object store, the
# compiler's own output, and the throwaway prototypes .gitignore already keeps
# out of the repository. The compiler's output is $BuildRoot itself and not the
# string 'build' beside it -- spelled twice, the two move apart and the sweep
# starts walking the directory it was told to skip.
$OdinFormatExcludedDirectories = @(
	(Join-Path $RepoRoot '.git')
	$BuildRoot
	(Join-Path $RepoRoot '.scratch')
) | ForEach-Object { [System.IO.Path]::GetFullPath($_) + [System.IO.Path]::DirectorySeparatorChar }

# The binaries this repository produces. Data rather than prose, so the GUI
# binary ADR-0004 promises is one more entry here and not a rewrite:
#
#   @{ Name = 'transcibr'; Package = 'gui'; Subsystem = 'windows'; Smoke = $false }
#
# Subsystem is stated rather than assumed. Console is already the default for a
# package named main, but the two binaries differ by exactly that flag, so
# neither is implicit -- and the build verifies it in the PE header afterwards.
# Smoke marks a target that can be run headless and asked for its version.
$OdinTargets = @(
	[pscustomobject]@{
		Name      = 'transcibr-cli'
		Package   = 'cli'
		Subsystem = 'console'
		Smoke     = $true
	}
)

# IMAGE_SUBSYSTEM_WINDOWS_GUI and _CUI, as the PE optional header spells them.
$PeSubsystemCodes = @{
	'windows' = 2
	'console' = 3
}

# Packages that legitimately collect no tests. The sweep fails any package not
# named here that collects zero -- that is the trap this repository's test
# command exists to close -- and equally fails a package named here that DOES
# collect tests, so the list cannot quietly go stale (CLAUDE.md rule A3).
$OdinPackagesWithoutTests = @(
	# package main: an entry point thin enough to read. Logic worth testing
	# belongs in the pure core instead (ADR-0009).
	'cli'
)

# One tool of this toolchain, found the one way all of them are found: the
# environment variable that names it outright, then PATH, then the default
# install location. Nothing here is on PATH on the development machine, and none
# of it should need a contributor to edit theirs.
#
# The EMPTY STRING means not found, rather than a throw, because what that costs
# is the caller's to decide and the two callers do not agree: a missing compiler
# is the end of the matter, and a missing formatter is not (see
# Resolve-OdinFormatter).
function Resolve-ToolPath {
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $Declared,
		[Parameter(Mandatory)] [string] $Fallback
	)

	if ($Declared -ne '') {
		if (-not (Test-Path -LiteralPath $Declared)) {
			return ''
		}
		return (Resolve-Path -LiteralPath $Declared).Path
	}

	$onPath = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
	if ($onPath) {
		return $onPath.Source
	}
	if (Test-Path -LiteralPath $Fallback) {
		return $Fallback
	}
	return ''
}

# A pinned tool that is not the pinned one: refused in CI, warned about anywhere
# else. ONE copy of the policy, because it is one policy -- it was written out
# twice, at length, and two copies of a rule are two rules the moment one moves.
#
# An unpinned toolchain turns an upstream change into a build failure on an
# unrelated commit and makes "it passed yesterday" unanswerable, so the shared
# answer -- what CI says about a branch -- comes from the pinned tools and
# nothing else.
#
# A hard local refusal buys nothing on top of that and costs a great deal. The
# first upstream retag, or the first contributor whose nightly is a week off,
# makes the repository unbuildable and untestable for them until the pin moves
# -- and the warning already tells them how, while CI still catches a change
# that only works on their toolchain.
function Confirm-PinnedTool {
	param(
		[Parameter(Mandatory)] [string] $Mismatch,
		[Parameter(Mandatory)] [string] $Local,
		[Parameter(Mandatory)] [string] $Remedy
	)

	if ($env:CI) {
		throw "$Mismatch`nCI runs the pinned toolchain and nothing else. $Remedy"
	}
	Write-Warning "$Mismatch`n$Local $Remedy"
}

# The Odin compiler. Set $env:ODIN to override; this is the only copy of the
# fallback path.
function Resolve-OdinCompiler {
	$odin = Resolve-ToolPath -Name 'odin' -Declared $env:ODIN -Fallback 'C:\Odin\dist\odin.exe'
	if ($odin -eq '') {
		if ($env:ODIN) {
			throw "ODIN is set to '$env:ODIN' but no file is there."
		}
		throw "Cannot find the Odin compiler. Put 'odin' on PATH or set `$env:ODIN to its full path."
	}

	Confirm-OdinVersion -Odin $odin
	return $odin
}

# Kill a process and everything it started.
#
# The TREE and not the process: `odin test` builds a test executable and then
# runs it, so the thing that hangs is the compiler's child. Killing the compiler
# alone leaves that child running, still holding the report file open and, in
# this repository's real workload, a model resident in VRAM.
#
# taskkill rather than .Kill(), whose tree-killing overload arrived in .NET Core
# 3.0 and is not on the .NET Framework that PowerShell 5.1 runs. Best effort
# throughout: a process that exited between the wait and the kill is the outcome
# being asked for, not an error to report.
function Stop-ProcessTree {
	param([Parameter(Mandatory)] [int] $Id)

	$ErrorActionPreference = 'Continue'
	& taskkill.exe '/T' '/F' '/PID' $Id 2>$null | Out-Null
}

# One argument, escaped the way CommandLineToArgvW un-escapes it.
#
# Windows has no array form of a command line -- CreateProcessW takes a single
# string -- and Start-Process joins -ArgumentList with spaces and nothing else,
# so `-out:C:\path with space\a.exe` arrives at the child as three arguments.
# The .NET collection that does this properly, ProcessStartInfo.ArgumentList,
# landed in .NET Core 2.1 and is not on the .NET Framework PowerShell 5.1 runs.
#
# Quote when the value holds a space, a tab or a quote; double any run of
# backslashes that MEETS a quote, including the closing one, and leave every
# other backslash alone. `C:\path with space\` is the case that rule exists for:
# quoting it naively ends the argument in `\"`, which is an escaped quote.
function ConvertTo-NativeArgument {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Value)

	if (($Value -ne '') -and ($Value -notmatch '[ \t"]')) {
		return $Value
	}

	# Built with string repetition rather than StringBuilder.Append(char, int):
	# PowerShell picks that overload by converting a one-character string to a
	# char, and the scripts run under 5.1 locally and pwsh in CI. A quoter that
	# resolves differently on the two would break the checkout-path-with-a-space
	# case on exactly one of them.
	$quoted = New-Object System.Text.StringBuilder
	[void] $quoted.Append('"')
	$slashes = 0
	foreach ($char in $Value.ToCharArray()) {
		if ($char -eq '\') {
			$slashes += 1
			continue
		}
		if ($char -eq '"') {
			[void] $quoted.Append('\' * ($slashes * 2 + 1))
		}
		else {
			[void] $quoted.Append('\' * $slashes)
		}
		$slashes = 0
		[void] $quoted.Append([string] $char)
	}
	[void] $quoted.Append('\' * ($slashes * 2))
	[void] $quoted.Append('"')
	return $quoted.ToString()
}

# Start a native command, escaping every argument on the way and caching the
# handle on the way out. The one start site, so neither of those can be
# remembered at one call site and forgotten at the next.
#
# STARTED rather than invoked with `&`, because a synchronous native call cannot
# be interrupted and nothing in the toolchain has a ceiling of its own -- see
# $OdinCommandTimeoutSeconds for what hangs and why it matters. It also settles
# the $ErrorActionPreference trap the `&` form carried: the test runner writes
# its entire log to stderr, and a caller that merged the streams --
# `.\scripts\test.ps1 2>&1`, or `*>` to a file -- had PowerShell wrap every one
# of those lines in an ErrorRecord, turning the first INFO line of a good run
# into a terminating error under 'Stop'. A started child's streams never enter
# the PowerShell pipeline at all.
#
# $OutFile captures standard output where a caller has to read it. Standard error
# is never redirected: it is the stream the compiler and the test runner report
# through, and a developer watching a build must see it as it happens.
function Start-NativeProcess {
	param(
		[Parameter(Mandatory)] [string] $Command,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Arguments,
		[string] $OutFile = ''
	)

	$options = @{ FilePath = $Command; NoNewWindow = $true; PassThru = $true }
	if ($Arguments.Count -gt 0) {
		$options.ArgumentList = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' ')
	}
	if ($OutFile -ne '') {
		$options.RedirectStandardOutput = $OutFile
	}
	$started = Start-Process @options

	# Touching .Handle makes the Process object cache the native handle. Without
	# it .ExitCode reads back empty once the child is gone, and a perfectly good
	# run reports no verdict at all. It has to happen HERE, at the start site:
	# measured, asking for it after the child has exited does not work.
	$null = $started.Handle
	return $started
}

# Wait for a started process under a wall-clock ceiling, killing its tree if the
# ceiling is hit. Returns the exit code and whether it was hit; the code is -1
# where the kill left nothing to read.
#
# The TREE and not the process, and the caller must have cached the handle --
# Start-NativeProcess and scripts\selftest.ps1's Start-FixtureScript both do,
# which is why the policy is written once here and not three times.
function Wait-ProcessTree {
	param(
		[Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
		[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $TimeoutSeconds
	)

	if ($Process.WaitForExit($TimeoutSeconds * 1000)) {
		return [pscustomobject]@{ ExitCode = $Process.ExitCode; TimedOut = $false }
	}

	Stop-ProcessTree -Id $Process.Id
	$code = -1
	if ($Process.WaitForExit($ProcessKillGraceSeconds * 1000)) {
		$code = $Process.ExitCode
	}
	return [pscustomobject]@{ ExitCode = $code; TimedOut = $true }
}

# Run a native command under a wall-clock ceiling, letting its output through to
# the console untouched. Returns the exit code and whether the ceiling was hit.
function Invoke-NativeCommand {
	param(
		[Parameter(Mandatory)] [string] $Command,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Arguments,
		[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $TimeoutSeconds
	)

	$ErrorActionPreference = 'Continue'
	$started = Start-NativeProcess -Command $Command -Arguments $Arguments
	return Wait-ProcessTree -Process $started -TimeoutSeconds $TimeoutSeconds
}

# The same call with standard output CAPTURED instead of passed through, for the
# two places that need to read what a program printed: the version check and the
# build's smoke test. Under the same ceiling and through the same quoter -- the
# smoke test runs the binary this repository has just compiled, and a `main` that
# wedges is a build command that never comes back.
function Read-NativeOutput {
	param(
		[Parameter(Mandatory)] [string] $Command,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Arguments,
		[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $TimeoutSeconds
	)

	$ErrorActionPreference = 'Continue'
	$capture = New-CapturePath -Extension 'out'
	try {
		$started = Start-NativeProcess -Command $Command -Arguments $Arguments -OutFile $capture
		$run = Wait-ProcessTree -Process $started -TimeoutSeconds $TimeoutSeconds

		$text = ''
		if (Test-Path -LiteralPath $capture) {
			$text = [System.IO.File]::ReadAllText($capture)
		}
		return [pscustomobject]@{ Output = $text.Trim(); ExitCode = $run.ExitCode; TimedOut = $run.TimedOut }
	}
	finally {
		Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
	}
}

# The compiler pin, under the policy Confirm-PinnedTool sets out.
function Confirm-OdinVersion {
	param([Parameter(Mandatory)] [string] $Odin)

	$reported = Read-NativeOutput -Command $Odin -Arguments @('version') -TimeoutSeconds $OdinCommandTimeoutSeconds
	if ($reported.TimedOut) {
		throw "'$Odin version' did not finish within $OdinCommandTimeoutSeconds seconds and was killed."
	}
	if ($reported.ExitCode -ne 0) {
		throw "'$Odin version' exited $($reported.ExitCode)."
	}

	$match = [regex]::Match($reported.Output, 'version\s+(\S+)')
	if (-not $match.Success) {
		throw "Cannot read a version out of '$($reported.Output)'."
	}

	$found = $match.Groups[1].Value
	if ($found -eq $OdinVersionPin) {
		return
	}

	$mismatch = @"
Odin version mismatch.
  expected: $OdinVersionPin (the pin in scripts\common.ps1)
  found:    $found ($Odin)
"@
	# The way out, said once for both branches. The two spellings of the pin move
	# together or CI downloads one compiler and then refuses it.
	$remedy = 'Point $env:ODIN at the pinned compiler, or move $OdinVersionPin and $OdinReleaseTag together in scripts\common.ps1 if you mean to move the pin.'

	Confirm-PinnedTool -Mismatch $mismatch -Remedy $remedy `
		-Local 'Continuing on this one. CI will not: anything that builds here and not on the pinned compiler fails there instead.'
}

# A file's SHA-256, uppercase hex.
#
# Through .NET rather than Get-FileHash, which is NOT always there. CI runs
# these scripts under pwsh 7, and scripts\selftest.ps1 starts its fixtures with
# powershell.exe -- a 5.1 child that inherits pwsh's PSModulePath, where
# Get-FileHash does not resolve. Locally it is present and everything passed;
# in CI every fixture that reached the formatter pin died on
# "The term 'Get-FileHash' is not recognized", and the failure was in the
# fixture rather than in the thing under test.
#
# The BCL is on both hosts by construction. Streamed rather than read whole:
# the file is a megabyte today and this says nothing about how large a pinned
# binary is allowed to get.
function Get-FileSha256 {
	param([Parameter(Mandatory)] [string] $Path)

	$sha = [System.Security.Cryptography.SHA256]::Create()
	try {
		$stream = [System.IO.File]::OpenRead($Path)
		try {
			$hash = $sha.ComputeHash($stream)
		}
		finally {
			$stream.Dispose()
		}
	}
	finally {
		$sha.Dispose()
	}
	return [System.BitConverter]::ToString($hash).Replace('-', '')
}

# odinfmt, resolved the way the compiler is -- and MISSING the way a mismatched
# one is: warned about locally, refused under CI.
#
# The two were not treated alike, and the asymmetry ran the wrong way round. A
# formatter whose build did not match the pin warned and carried on; a formatter
# that was not installed at all failed the build outright, so a contributor with
# the pinned compiler but without the ols zip could not build anything at all.
# Confirm-PinnedTool argues against exactly that, at length, and nothing in the
# argument is about compilers.
#
# -Optional is the BUILD's answer and not the format command's. build.ps1 has a
# compiler and work to do, and rule S1 is still enforced against the branch by
# CI, which installs the pinned formatter and refuses to skip anything.
# format.ps1 has nothing to do without a formatter, so asking it to run without
# one is a request that can only be refused.
#
# The empty string is what a skipped resolve returns; the caller that passed
# -Optional is the only one that can receive it.
function Resolve-OdinFormatter {
	param([switch] $Optional)

	$fallback = 'C:\Odin\dist\odinfmt.exe'
	$odinfmt = Resolve-ToolPath -Name 'odinfmt' -Declared $env:ODINFMT -Fallback $fallback
	if ($odinfmt -ne '') {
		Confirm-OdinfmtVersion -Odinfmt $odinfmt
		return $odinfmt
	}

	$missing = "Cannot find odinfmt. It ships in $OdinfmtAsset on the ols release $OdinfmtReleaseTag (https://github.com/DanielGavin/ols/releases), not with the Odin compiler."
	if ($env:ODINFMT) {
		$missing = "ODINFMT is set to '$env:ODINFMT' but no file is there."
	}
	$remedy = "Put 'odinfmt' on PATH, drop it at $fallback, or set `$env:ODINFMT to its full path."

	if (-not $Optional) {
		throw "$missing $remedy"
	}
	Confirm-PinnedTool -Mismatch $missing -Remedy $remedy `
		-Local 'Building without the formatting check on this one. CI will not: a misformatted file fails there instead.'
	return ''
}

# The formatter pin, under the policy Confirm-PinnedTool sets out.
#
# By CONTENT, because odinfmt has no version flag to ask (see $OdinfmtSha256).
# A formatter is a stronger case for pinning than a compiler, not a weaker one:
# two builds that lay out one line differently make every file in the repository
# fail a check that passed yesterday, on a commit that touched none of them.
function Confirm-OdinfmtVersion {
	param([Parameter(Mandatory)] [string] $Odinfmt)

	$found = Get-FileSha256 -Path $Odinfmt
	if ($found -eq $OdinfmtSha256) {
		return
	}

	$mismatch = @"
odinfmt build mismatch.
  expected SHA-256: $OdinfmtSha256 (the pin in scripts\common.ps1, from ols $OdinfmtReleaseTag)
  found SHA-256:    $found ($Odinfmt)
"@
	$remedy = "Point `$env:ODINFMT at $OdinfmtAsset from the ols release $OdinfmtReleaseTag, or move `$OdinfmtSha256 and `$OdinfmtReleaseTag together in scripts\common.ps1 if you mean to move the pin."

	Confirm-PinnedTool -Mismatch $mismatch -Remedy $remedy `
		-Local 'Continuing on this one. CI will not: anything this build formats differently from the pinned one fails there instead.'
}

# One value against the type odinfmt reads that key as. The fault, or an empty
# string where there is none.
function Test-OdinFormatConfigValue {
	param(
		[Parameter(Mandatory)] [string] $Key,
		[Parameter(Mandatory)] [AllowNull()] $Value,
		[Parameter(Mandatory)] [string] $Expected
	)

	$found = 'null'
	if ($null -ne $Value) {
		if ($Value -is [bool]) { $found = "the boolean $(([string] $Value).ToLower())" }
		elseif (($Value -is [int]) -or ($Value -is [long])) { $found = "the whole number $Value" }
		elseif ($Value -is [string]) { $found = "the string '$Value'" }
		else { $found = "a $($Value.GetType().Name) ($Value)" }
	}

	if ($Expected -eq 'int') {
		if (($Value -is [int]) -or ($Value -is [long])) { return '' }
		return "'$Key' is $found; odinfmt reads it as a whole number."
	}
	if ($Expected -eq 'bool') {
		if ($Value -is [bool]) { return '' }
		return "'$Key' is $found; odinfmt reads it as true or false."
	}

	# An enum, and the names are odinfmt's own, matched case-sensitively because
	# that is how it matches them.
	$names = @($Expected -split '\|')
	if (($Value -is [string]) -and ($names -ccontains $Value)) { return '' }
	return "'$Key' is $found; odinfmt reads it as one of $($names -join ', ')."
}

# Prove odinfmt.json says what this repository means, key by key.
#
# Not a formality, and not something the formatter can be asked. odinfmt's
# find_config_file_or_default returns its built-in default_style whenever
# json.unmarshal fails and says NOTHING -- but that is only the loudest of the
# ways a config goes wrong in silence, and MEASURED against the pinned ols build
# they do not even fail alike:
#
#   { "character_widht": 100 }   an unknown key is ignored; the rest applies
#   { "spaces": "8" }            a string where an int belongs is COERCED to 8
#   { "newline_style": "NOPE" }  an unknown enum name leaves the field at default
#   { "tabs": 1 }                an int where a bool belongs drops the WHOLE file
#   { "tabs": null }             null is read as false
#   { }                          an absent key takes odinfmt's own default, and
#                                that default is platform-dependent: newline_style
#                                is CRLF on Windows and LF everywhere else
#   { "tabs": true, }            ACCEPTED, and applied in full. odinfmt reads
#   { /* or */ // a comment }    this file with core:encoding/json, whose
#                                DEFAULT_SPECIFICATION is JSON5 -- so the two
#                                likeliest syntax errors are not errors to it at
#                                all. Measured: a config carrying either formats
#                                byte-identically to the same config without it,
#                                and differently from no config at all.
#
# This was first written as a PROBE: format a small file, read the indentation
# and line endings back out of the answer, the way Assert-PeSubsystem reads the
# header rather than the flag that built it. That cannot work here, and no probe
# can. odinfmt's built-in Windows default is already tabs, CRLF and
# character_width 100 -- so on the only platform this repository supports,
# formatting with this config and with no config at all is byte-identical, and a
# probe measuring the difference agrees with itself whatever the file says. The
# hole it was written to close stayed open: `"tabs": "true"` passed it green.
#
# So the file is checked against the SCHEMA instead, which covers the class
# rather than the incident. Every key odinfmt reads must be present, spelled the
# way odinfmt spells it and typed the way odinfmt types it, and nothing else may
# appear. Present as well as correct, because a key left out is not a key left
# alone: it silently takes a default this repository did not choose.
function Confirm-OdinFormatConfig {
	if (-not (Test-Path -LiteralPath $OdinFormatConfig)) {
		throw "no $OdinFormatConfig. Without it odinfmt formats to a built-in default that differs by platform, and this check would be measuring against a style nobody chose."
	}

	try {
		$declared = Get-Content -LiteralPath $OdinFormatConfig -Raw | ConvertFrom-Json
	}
	catch {
		# Refused, not diagnosed. This parser is the STRICTER of the two -- odinfmt
		# reads the file as JSON5 and would have taken a trailing comma or a
		# comment in its stride -- so the honest claim is that the file no longer
		# says which way odinfmt went, not that odinfmt ignored it.
		throw "$OdinFormatConfig is not valid JSON: $($_.Exception.Message). Refused rather than guessed at: odinfmt reads this file as JSON5, which accepts a trailing comma and a comment that this parser will not, so the file alone cannot say whether odinfmt read it or fell back to its own default -- and that default is platform-dependent."
	}
	if ($declared -isnot [System.Management.Automation.PSCustomObject]) {
		throw "$OdinFormatConfig is not a JSON object, so there is nothing for odinfmt to read printer.Config out of."
	}

	# Case-SENSITIVE on both sides. PowerShell compares names case-insensitively
	# by default, which would read `Tabs` as the key `tabs` and wave through a
	# spelling odinfmt does not answer to.
	$known = @($OdinFormatConfigSchema.Keys)
	$present = @($declared.PSObject.Properties.Name)
	$faults = @()

	foreach ($key in $present) {
		if ($known -cnotcontains $key) {
			$faults += "  - '$key' is not a key odinfmt reads. It is ignored in silence."
		}
	}
	foreach ($key in $known) {
		if ($present -cnotcontains $key) {
			$faults += "  - '$key' is missing. odinfmt would use its own default, which differs by platform."
			continue
		}
		$fault = Test-OdinFormatConfigValue -Key $key -Value $declared.$key -Expected $OdinFormatConfigSchema[$key]
		if ($fault -ne '') {
			$faults += "  - $fault"
		}
	}

	if ($faults.Count -gt 0) {
		throw "$OdinFormatConfig is not the config odinfmt would read:`n$($faults -join "`n")`nodinfmt reports none of this. It ignores what it cannot read and formats to its own default, and every check here would pass against a style nobody chose."
	}
}

# What odinfmt would write for one file, as BYTES.
#
# Bytes and not text, because the difference that matters is sometimes invisible
# as text: src\transcript\repetition.odin carried a UTF-8 BOM that
# [System.IO.File]::ReadAllText strips from the file AND from odinfmt's answer,
# so a text comparison called it clean. Line endings go the same way through a
# careless read.
#
# Started through Start-NativeProcess like every other child this repository
# runs -- the Windows argv quoter is not optional the moment a checkout path
# holds a space, and nothing in the toolchain has a timeout of its own -- and
# captured through New-CapturePath like every other child's output, so the file
# this leaves behind when killed is a file something sweeps.
function Format-OdinSource {
	param(
		[Parameter(Mandatory)] [string] $Odinfmt,
		[Parameter(Mandatory)] [string] $Path,
		[ValidateRange(1, 86400)] [int] $TimeoutSeconds = $OdinCommandTimeoutSeconds
	)

	$ErrorActionPreference = 'Continue'
	$capture = New-CapturePath -Extension 'odin'
	try {
		$arguments = @("-path:$Path", "-config:$OdinFormatConfig")
		$started = Start-NativeProcess -Command $Odinfmt -Arguments $arguments -OutFile $capture
		$run = Wait-ProcessTree -Process $started -TimeoutSeconds $TimeoutSeconds

		if ($run.TimedOut) {
			throw "odinfmt did not finish formatting $Path within $TimeoutSeconds seconds and was killed."
		}
		# Checked, but it is not what catches a file odinfmt cannot read. This once
		# claimed odinfmt "exits non-zero when it cannot PARSE the file", and it
		# does not: measured against the pinned build, an unparseable file gives
		# exit ZERO, an empty standard output and a diagnostic on standard error.
		# So the guard never fired, and neither did the one below it -- the
		# redirect creates the capture file whether anything is written to it or
		# not. What actually stopped the run was Set-StrictMode, several frames
		# later, turning the empty answer into "The property 'Length' cannot be
		# found on this object": closed, but by accident, naming no file, and one
		# StrictMode change away from -Fix writing nothing over a source file.
		if ($run.ExitCode -ne 0) {
			throw "odinfmt exited $($run.ExitCode) on $Path."
		}
		if (-not (Test-Path -LiteralPath $capture)) {
			throw "odinfmt wrote nothing at all for $Path."
		}

		# EMPTY is the answer that means failure, and it is checked here rather
		# than left to a caller: the shortest legal Odin file is a package clause,
		# so no bytes is never a formatting result. Named against the file, because
		# that is the only thing pointing at what to go and look at.
		$bytes = [System.IO.File]::ReadAllBytes($capture)
		if ($bytes.Length -eq 0) {
			throw "odinfmt produced no output for $Path, so it could not parse the file. Its diagnostic is on standard error, above."
		}

		# Returned as ONE object: a bare `return $bytes` unrolls the array into the
		# pipeline, and a one-byte answer comes back as a scalar with no .Length.
		return , $bytes
	}
	finally {
		Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
	}
}

# A path as it is spelled relative to a root, forward-slashed: `version`,
# `net/winhttp`, `src/version/version.odin`. The empty string is the root itself.
#
# Guarded rather than a bare Substring: a subst drive, a UNC path or a
# junctioned checkout can hand back a path that does not share a prefix with the
# root at all, and trimming a length off that yields a garbled label or an
# exception. Showing the whole path is the honest answer in that case.
#
# One copy, used by both callers. Get-OdinSource carried its own, under a
# comment saying it was "Guarded like Get-OdinPackageName" -- so the duplication
# had already been noticed and written down instead of removed.
function Get-RelativeName {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [string] $Root
	)

	$full = [System.IO.Path]::GetFullPath($Path)
	$root = $Root.TrimEnd('\', '/')
	if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
		return ''
	}

	$prefix = $root + [System.IO.Path]::DirectorySeparatorChar
	if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $full.Substring($prefix.Length).Replace('\', '/')
	}

	return $full
}

# The src-relative name of a package directory: `version`, `cli`, `net/winhttp`.
# Used as the sweep's label and as the key the test-less list is matched against.
function Get-OdinPackageName {
	param([Parameter(Mandatory)] [string] $Path)

	$name = Get-RelativeName -Path $Path -Root $SrcRoot
	if ($name -eq '') {
		return 'src'
	}
	return $name
}

# Every .odin file under a root, as FileInfo.
#
# -Filter rather than a bare walk plus a Where-Object: the filter is applied by
# the filesystem, and the repository root holds several hundred files inside
# .git alone that there is no reason to materialise and then discard. The
# extension is checked afterwards ALL THE SAME -- Windows matches a -Filter
# against a file's 8.3 short name as well as its long one, so `*.odin` also
# matches a `notes.odinography` whose short name happens to end `.ODI`.
#
# -Force walks hidden directories and -ErrorAction Stop turns an unreadable one
# into a crash: discovery that silently returns a short list is the one failure
# a user cannot detect (ADR-0009), and it reads as a clean pass.
function Get-OdinFile {
	param([Parameter(Mandatory)] [string] $Root)

	return Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Filter '*.odin' -ErrorAction Stop |
		Where-Object { $_.Extension -eq '.odin' }
}

# Every directory under src\ holding at least one .odin file is a package.
# Discovered rather than listed, so a new package cannot be added without the
# test sweep picking it up.
#
# -Force walks hidden directories and -ErrorAction Stop turns an unreadable one
# into a crash: discovery that silently returns a short list is the one failure
# a user cannot detect (ADR-0009), and it reads as a clean pass.
#
# PowerShell unrolls a one-element result to a bare object on the way out, and
# under Set-StrictMode `.Count` on that throws -- which once skipped the sweep's
# own failure check and reported success. EVERY caller therefore wraps the call
# in @(); scripts\selftest.ps1 keeps a one-package repository in the suite so
# that contract cannot rot again.
function Get-OdinPackage {
	$directories = @(Get-OdinFile -Root $SrcRoot | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)

	$packages = [System.Collections.Generic.List[object]]::new()
	foreach ($directory in $directories) {
		$packages.Add([pscustomobject]@{
				Path = $directory
				Name = Get-OdinPackageName -Path $directory
			})
	}
	return $packages.ToArray()
}

# Every .odin file in the repository, wherever it lives. Discovered rather than
# listed, for the reason $OdinFormatExcludedDirectories sets out: a file list
# stops covering the file somebody adds tomorrow and nothing says so.
#
# $RepoRoot and not $SrcRoot, because src\ is not where all the Odin is --
# docs\reference\ holds a spike that is still Odin somebody reads and copies
# from. A check scoped to src\ would leave it drifting.
#
# -Force walks hidden directories and -ErrorAction Stop turns an unreadable one
# into a crash, exactly as Get-OdinPackage does: discovery that silently returns
# a short list is the one failure a user cannot detect (ADR-0009), and it reads
# as a clean pass.
#
# Wrapped in @() by EVERY caller: PowerShell unrolls a one-element result to a
# bare object, and under Set-StrictMode `.Count` on that throws.
function Get-OdinSource {
	$sources = [System.Collections.Generic.List[object]]::new()
	foreach ($file in @(Get-OdinFile -Root $RepoRoot)) {
		$full = [System.IO.Path]::GetFullPath($file.FullName)
		$skip = $false
		foreach ($directory in $OdinFormatExcludedDirectories) {
			if ($full.StartsWith($directory, [System.StringComparison]::OrdinalIgnoreCase)) {
				$skip = $true
				break
			}
		}
		if ($skip) {
			continue
		}

		# Repository-relative and forward-slashed, so the report names
		# `src/version/version.odin` rather than a machine-specific absolute path.
		$sources.Add([pscustomobject]@{ Path = $full; Name = (Get-RelativeName -Path $full -Root $RepoRoot) })
	}
	return $sources.ToArray()
}

# How many .odin files were looked at, and which of them odinfmt would rewrite,
# with what it would write. No misformatted files is the passing answer.
#
# The total comes back WITH the verdict rather than being counted again by the
# caller: format.ps1 walked the repository a second time purely to print a number
# this sweep already had, and a total taken from a second walk is a total that
# can disagree with the check it is reported beside.
#
# The sweep FAILS when it finds nothing to look at. A formatting check that
# covers zero files passes forever and reports the same green as one that
# checked everything -- the deny-by-default lesson this repository has now
# learned twice, in $OdinPackagesWithoutTests and in the test sweep's own
# zero-collected rule.
#
# Bounded as a WHOLE and not merely per file, which is the same defect the test
# sweep had and the same mechanism that fixed it ($OdinSweepTimeoutSeconds). One
# file's ceiling times however many files exist is not a bound anybody chose: at
# thirteen files it is 130 minutes against a 30-minute CI job, so a sweep that
# wedged would be reported by GitHub's job timeout, which names no file and
# prints no output, rather than by this naming the file. The clock starts before
# the config is read, because everything after that point is inside the budget.
function Get-OdinFormatReport {
	param(
		[Parameter(Mandatory)] [string] $Odinfmt,
		[ValidateRange(1, 86400)] [int] $SweepTimeoutSeconds = $OdinSweepTimeoutSeconds
	)

	$sweepEnd = (Get-Date).AddSeconds($SweepTimeoutSeconds)

	Confirm-OdinFormatConfig

	$sources = @(Get-OdinSource)
	if ($sources.Count -eq 0) {
		throw "no .odin files found under $RepoRoot, so this check would pass having compared nothing."
	}

	$misformatted = @()
	$checked = 0
	foreach ($source in $sources) {
		# What is left of the sweep's budget, which is what this file gets if that
		# is less than its own ceiling. A file left with none of it is not started:
		# a run nobody waits for cannot be reported, and this sweep has no verdict
		# to give about the files it never reached.
		$remaining = [int][math]::Floor(($sweepEnd - (Get-Date)).TotalSeconds)
		if ($remaining -lt 1) {
			throw "the format sweep's $SweepTimeoutSeconds-second budget ran out at $($source.Name), having checked $checked of $($sources.Count) file(s)."
		}
		$budget = [math]::Min($OdinCommandTimeoutSeconds, $remaining)

		$formatted = Format-OdinSource -Odinfmt $Odinfmt -Path $source.Path -TimeoutSeconds $budget
		$current = [System.IO.File]::ReadAllBytes($source.Path)
		$checked += 1

		# Bytes, not text: the BOM and the line endings are exactly the differences
		# a text comparison hides. See Format-OdinSource. SequenceEqual rather than
		# a PowerShell loop over the indices, which is about a hundred times slower
		# on a file this size and says nothing a reader could not already assume.
		if (-not [System.Linq.Enumerable]::SequenceEqual($current, $formatted)) {
			$misformatted += [pscustomobject]@{
				Path      = $source.Path
				Name      = $source.Name
				Formatted = $formatted
			}
		}
	}
	return [pscustomobject]@{ Total = $sources.Count; Misformatted = $misformatted }
}

# One file's contents replaced by another's, in a single step.
#
# Not [System.IO.File]::WriteAllBytes, which opens the destination with
# FileMode.Create: it TRUNCATES and then writes, so for the length of that write
# every byte of the source file is already gone, and a run killed inside it
# leaves a truncated or empty .odin file with nothing to say which. That window
# is wider than the one `odinfmt -w` carries, which was rejected here for
# leaving a `<name>_bk` behind when interrupted -- a file that is neither source
# nor artefact and is ignored by nothing.
#
# File.Replace closes both. The new bytes are written and closed under a
# neighbouring name first, and the destination then goes from all of the old
# bytes to all of the new ones in one rename; no backup is kept, because there
# is no moment at which one would be read. Beside the destination rather than in
# TEMP because Replace needs both on one volume, and named with an extension the
# sweep does not discover so a leaked one is never mistaken for source.
function Write-FileAtomically {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [byte[]] $Bytes
	)

	$staged = "$Path.$PID-$([System.Guid]::NewGuid().ToString('N')).odinfmt-tmp"
	try {
		[System.IO.File]::WriteAllBytes($staged, $Bytes)
		# [NullString]::Value and not $null: PowerShell converts $null to the EMPTY
		# STRING when it binds to a .NET string parameter, and File.Replace reads an
		# empty backup path as a path, failing with "The path is not of a legal
		# form" after the staged file has already been written.
		[System.IO.File]::Replace($staged, $Path, [NullString]::Value)
	}
	finally {
		# However this ended, nothing of it is left beside the source. A Replace
		# that succeeded has already consumed the staged file.
		Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
	}
}

# The sweep as a single verdict, for callers that only want it to pass -- which
# is build.ps1, so that a misformatted file fails the BUILD and not merely a
# check somebody remembers to run. Rule S1 is a rule; the vet flags beside it
# already fail the build, and this is the third of them.
function Assert-OdinFormatting {
	param([Parameter(Mandatory)] [string] $Odinfmt)

	$misformatted = @((Get-OdinFormatReport -Odinfmt $Odinfmt).Misformatted)
	if ($misformatted.Count -eq 0) {
		return
	}

	$named = ($misformatted | ForEach-Object { "  - $($_.Name)" }) -join "`n"
	throw "$($misformatted.Count) file(s) are not formatted as odinfmt.json says (CLAUDE.md rule S1):`n$named`nRun .\scripts\format.ps1 -Fix to rewrite them."
}

# Reclaim what earlier runs left behind. test.ps1 names every artefact for the
# run that wrote it and deletes its own on the way out, so nothing will ever
# name again the files a KILLED run left -- or the files an older naming scheme
# wrote. Under build\ that is untidy; under the ProgramData fallback below it is
# a machine-wide directory that only ever grows, and no one looks in it.
#
# A day, so nothing in flight is ever a candidate: this repository's whole sweep
# takes seconds, and a concurrent run's artefacts are minutes old at the very
# most. Best effort throughout -- a file another process still holds open is not
# this run's verdict to deliver, and reclamation is not what either command is
# being asked for.
function Remove-StaleTestArtefact {
	param(
		[Parameter(Mandatory)] [string] $Root,
		# Which files under $Root are this repository's to reclaim. Everything,
		# under a directory this repository owns; NAMED, under one it merely
		# borrows -- the system temp directory belongs to the user and to every
		# other program on the machine.
		[string] $Pattern = '*'
	)

	$cutoff = (Get-Date).AddDays(-1)
	Get-ChildItem -LiteralPath $Root -File -Force -Filter $Pattern -ErrorAction SilentlyContinue |
		Where-Object { $_.LastWriteTime -lt $cutoff } |
		Remove-Item -Force -ErrorAction SilentlyContinue
}

# Where one child's captured output goes, named for the run that made it.
#
# ONE recipe. There were three, each spelling its own GUID-named temp file, and
# not one of them was ever swept: every capture is deleted on the way out, so
# what survives is what a KILLED run left behind -- in the system temp
# directory, which nobody looks in and which only grows. Reclaimed here the same
# way build\odin-test is, filtered to this repository's own names so the sweep
# is never pointed at somebody else's files.
#
# Swept once per process rather than once per capture: the sweep costs a
# directory listing, and there is one of these per .odin file.
$script:SweptCaptures = $false
function New-CapturePath {
	param([Parameter(Mandatory)] [string] $Extension)

	$root = [System.IO.Path]::GetTempPath()
	if (-not $script:SweptCaptures) {
		$script:SweptCaptures = $true
		Remove-StaleTestArtefact -Root $root -Pattern 'transcibr-capture-*'
	}
	return Join-Path $root "transcibr-capture-$PID-$([System.Guid]::NewGuid().ToString('N')).$Extension"
}

# A directory that exists and contains no space, for `odin test` to write the
# executable it builds and the runner to write its JSON report into.
#
# `odin test` builds a test binary and then runs it, and the command line it
# builds to do that is not quoted: any space in the executable's path is
# re-parsed as an argument separator and the compiler exits -1 with
# "Unknown argument encountered '<second word>'". The default output path is
# derived from the working directory, so a checkout under `C:\Users\John
# Smith\` breaks the sweep before a single test runs -- and CI never sees it,
# because a runner's D:\a\... path has no spaces. `odin build` is unaffected.
#
# build\ is where these belong and is the answer whenever the checkout allows
# it. Where it does not, the space-free property is CHOSEN rather than
# sanitised for: the 8.3 short name (`John Smith` -> `JOHNSM~1`) looks like the
# escape and is not one. Generation is a per-volume policy that can be off; it
# runs at creation time, so enabling it does not retroactively name a directory
# that already exists; and the lookup goes through Scripting.FileSystemObject,
# a raw COM failure wherever Windows Script Host is disabled by policy.
# ADR-0002 settles the same question the same way for the engine's cache.
function Get-OdinTestRoot {
	$preferred = Join-Path $BuildRoot 'odin-test'
	if ($preferred -notmatch ' ') {
		New-Item -ItemType Directory -Path $preferred -Force | Out-Null
		Remove-StaleTestArtefact -Root $preferred
		return $preferred
	}

	# ProgramData rather than the drive root: always present, writable without
	# elevation, and spelled without a space on every Windows install. Checked
	# all the same -- it is relocatable, and a chosen property that goes
	# unverified is the assumption this function exists to stop making.
	$advice = 'Check the repository out under a path with no space in it.'
	if (-not $env:ProgramData) {
		throw "$preferred contains a space and ProgramData is unset, so there is nowhere to put a test executable that odin test can then run. $advice"
	}

	$chosen = Join-Path $env:ProgramData 'transcibr\odin-test'
	if ($chosen -match ' ') {
		throw "$preferred contains a space and so does the fallback $chosen. $advice"
	}

	try {
		New-Item -ItemType Directory -Path $chosen -Force -ErrorAction Stop | Out-Null
	}
	catch {
		throw "$preferred contains a space, and $chosen could not be created to hold the test executables instead: $($_.Exception.Message) $advice"
	}
	Remove-StaleTestArtefact -Root $chosen
	return $chosen
}

# The subsystem an image was actually built for, read out of its PE optional
# header. Reading the header is the only check that proves ADR-0004's
# console/GUI split; running the binary and watching it print proves only that
# it runs, and trusting the flag that went in proves nothing at all.
function Assert-PeSubsystem {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [ValidateSet('console', 'windows')] [string] $Subsystem
	)

	$bytes = [System.IO.File]::ReadAllBytes($Path)
	if ($bytes.Length -lt 64) {
		throw "$Path is $($bytes.Length) bytes, too small to be a PE image."
	}
	if (($bytes[0] -ne 0x4D) -or ($bytes[1] -ne 0x5A)) {
		throw "$Path does not start with the MZ signature."
	}

	$peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
	# PE signature (4 bytes) + COFF header (20 bytes) + 68 bytes into the
	# optional header, where Subsystem sits in both PE32 and PE32+.
	$subsystemOffset = $peOffset + 4 + 20 + 68
	if (($peOffset -lt 0) -or ($bytes.Length -lt ($subsystemOffset + 2))) {
		throw "$Path has a PE header offset of $peOffset that runs past its $($bytes.Length) bytes."
	}
	if (($bytes[$peOffset] -ne 0x50) -or ($bytes[$peOffset + 1] -ne 0x45)) {
		throw "$Path has no PE signature at offset $peOffset."
	}

	$expected = $PeSubsystemCodes[$Subsystem]
	$found = [System.BitConverter]::ToUInt16($bytes, $subsystemOffset)
	if ($found -ne $expected) {
		throw "$Path is subsystem $found, expected $expected ($Subsystem)."
	}
}
