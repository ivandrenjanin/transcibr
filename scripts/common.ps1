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

# The vet set's other half: the names every .odin file declares for itself, on a
# `#+vet` line above its own `package` clause.
#
# Here rather than in $OdinVetFlags because there is nowhere else to put them. At
# the pin these are FILE TAGS and nothing else -- `odin build
# -vet-explicit-allocators` answers `Unknown flag` -- so a name that is to apply
# to the whole repository has to be written into every file, and this is the one
# declaration saying which names those are.
#
# `explicit-allocators` is ADR-0010 made mechanical. That ADR's rule is that
# nothing crossing a thread boundary comes from `context.temp_allocator` and that
# every procedure which allocates takes its allocator explicitly; the tag turns a
# call that lets Odin fill an `allocator` parameter from the context into
# `Parameter 'allocator' of type 'Allocator' must be explicitly provided in
# procedure call`, at the call site, on every build.
#
# Measured against the pin, dev-2026-07-nightly:819fdc7:
#
#   - the tag ADDS to the command-line set rather than replacing it, so a tagged
#     file still fails -vet-tabs and -vet-unused-variables;
#   - several names on one `#+vet` line all fire, and a `#+vet` line stacks with
#     a file tag of another kind on the line below it -- which is what makes this
#     a list rather than a string;
#   - and the tag is PER FILE. A package holding one tagged file and one untagged
#     sibling builds clean, with the sibling's implicit allocators unchecked.
#
# That last one is why Assert-OdinVetTagPolicy exists. The two ways a tag can be
# WRONG are already loud and need nothing from this repository -- a misspelled
# name is `Syntax Error: Invalid vet flag name`, and a tag below the package
# clause is `Lines starting with #+ (file tags) are only allowed before the
# package line`. ABSENCE is the silent one, and it is silent per file: the
# repository goes on building, and the file added tomorrow is simply not checked.
$OdinFileVetTags = @(
	'explicit-allocators'
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

# What -Fix names the bytes it is about to swap in, while it still has both files
# (see Write-FileAtomically). Deliberately an extension Get-OdinSource does not
# discover, so a leaked one is never mistaken for source and never formatted.
#
# ONE spelling, because two things depend on it and they must not drift: the
# procedure that names the file, and the sweep in Get-OdinFormatReport that
# reclaims the ones a killed run stranded. Spelled twice, the sweep goes on
# looking for a name nothing writes any more and says nothing about it -- which
# is the failure $OdinFormatExcludedDirectories records the same lesson for.
$OdinFormatStagedSuffix = '.odinfmt-tmp'

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

	$sources = @(Get-OdinCheckedSource)

	# What a killed -Fix stranded beside a source, reclaimed the way every other
	# artefact this repository leaks is. Write-FileAtomically removes its staged
	# file however the replace ended, so a survivor is a run hard-killed between
	# the write and the rename -- and no later run will ever name that file again.
	# `git status` does show it, which is what keeps it harmless; being visible is
	# not the same as being cleaned up.
	#
	# The directories holding sources, and only those: a repository-wide walk for
	# this would be a second discovery pass disagreeing with the one that matters.
	# Age is what protects a CONCURRENT rewrite, whose staged file is seconds old
	# -- deleting that one would corrupt the run it belongs to.
	foreach ($directory in @($sources | ForEach-Object { [System.IO.Path]::GetDirectoryName($_.Path) } | Sort-Object -Unique)) {
		Remove-StaleTestArtefact -Root $directory -Pattern "*$OdinFormatStagedSuffix"
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
# TEMP because Replace needs both on one volume, and named with the extension
# $OdinFormatStagedSuffix spells -- one the sweep does not discover, so a leaked
# one is never mistaken for source, and one Get-OdinFormatReport reclaims, so a
# run killed between the write and the rename does not strand it beside the
# source forever.
#
# DO NOT swap this back for a plain write. What this buys is the ABSENCE of that
# window, and nothing here can open a window to prove it is gone: staging a kill
# inside a .NET call is not something scripts\selftest.ps1 can do, and the revert
# leaves every case about the -Fix path green. What that suite pins instead is
# the MECHANISM -- "the rewrite swaps a new file in rather than writing over the
# old one" watches the destination's NTFS identity, which a truncating write
# keeps and a replace changes. That case is the only thing standing between this
# procedure and a quiet revert, so a change here that turns it red is the change
# this comment is about.
function Write-FileAtomically {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [byte[]] $Bytes
	)

	$staged = "$Path.$PID-$([System.Guid]::NewGuid().ToString('N'))$OdinFormatStagedSuffix"
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

# The lex of each file, kept for the run rather than redone per reader.
#
# Three checks read six answers out of these facts, and the walk below is the
# only expensive thing any of them does: it was running four times per file per
# build and taking the static phase from 749ms to 1067ms. Keyed on the exact
# text, which is sound because every reader here is a pure function of it -- and
# the whole sweep reads each file once, so the key is never a stale copy of a
# file that has since changed on disk.
$script:OdinLineFactMemo = @{}

# The only four characters that can open a comment or a literal, and therefore
# the only four that can make a line's code differ from the line. A line already
# in ordinary code and holding none of them needs no walk at all, which is most
# lines in most files -- and the walk is the whole cost of the scan.
$script:OdinLexTriggers = [char[]]@('/', '"', "'", '`')

# One fact per line of an Odin file: whether the line BEGINS in ordinary code,
# whether a comment OPENS anywhere on it, and the line's ORDINARY CODE with
# every comment, string and rune literal blanked to spaces.
#
# Code is what makes this the only lexer in the file. The readers below all need
# to count brackets or match a keyword without being fooled by one inside a
# string, and each of them used to walk the characters again to get it -- the
# result reader was 31 lines of this loop with the variables renamed. Blanking
# rather than deleting keeps every column where it was, so a position in Code is
# a position in Text, and two tokens either side of a deleted literal cannot
# fuse into one that was never written.
#
# ANYWHERE, and not at the first token. The reader asked the narrower question
# once, and `x := 1 // why` passed a check whose refusal reads "N comment(s)
# inside a procedure body" -- a complete-sounding guarantee over a scan that
# only ever looked at column one. Where the comment opens is already known: the
# loop below has to walk past strings and rune literals anyway to keep a raw
# string's contents from being read as code, so the answer costs nothing beyond
# reporting it.
#
# This is a lexer and not a regex, and the reason is one line in
# src\transcript\render.odin:
#
#   INLINE_SPECIALS :: `\` + "`" + `*_[]<|`
#
# Three string literals, one of which is a double-quoted backtick. Count
# backticks with a pattern and that file reads as having an unterminated raw
# string, after which every following line is misclassified. Odin's raw strings
# also SPAN LINES and take no escapes, so a line beginning `//` inside one is
# transcribed speech rather than a comment -- and this repository transcribes
# whatever somebody said. A checker that cannot tell those apart refuses a
# Recording for its contents.
#
# Block comments nest in Odin, so the depth is counted rather than flagged.
# Double-quoted strings and rune literals cannot span a line, so their state is
# not carried across one; raw strings and block comments are, which is the whole
# reason a line's opening state is worth reporting at all.
function Get-OdinLineFact {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$memo = $script:OdinLineFactMemo[$Text]
	if ($null -ne $memo) {
		return $memo
	}

	$facts = [System.Collections.Generic.List[object]]::new()
	$raw = $false
	$depth = 0

	foreach ($line in ($Text -split "`r?`n")) {
		$live = (-not $raw) -and ($depth -eq 0)

		if ($live -and ($line.IndexOfAny($script:OdinLexTriggers) -lt 0)) {
			$facts.Add([pscustomobject]@{
					Text    = $line
					Live    = $true
					Comment = $false
					Code    = $line
				})
			continue
		}

		# Set by the scan below, so the fact is added after it rather than before.
		# A comment that OPENS on a line the file was already inside a comment on
		# counts too -- `b */ // c` closes one and opens another, and the second is
		# a comment nothing else reports.
		$opens = $false
		$code = $line.ToCharArray()

		$i = 0
		while ($i -lt $line.Length) {
			$char = $line[$i]
			$next = ''
			if (($i + 1) -lt $line.Length) {
				$next = $line[$i + 1]
			}

			if ($depth -gt 0) {
				$code[$i] = ' '
				if (($char -eq '*') -and ($next -eq '/')) { $code[$i + 1] = ' '; $depth -= 1; $i += 2; continue }
				if (($char -eq '/') -and ($next -eq '*')) { $code[$i + 1] = ' '; $depth += 1; $i += 2; continue }
				$i += 1
				continue
			}
			if ($raw) {
				$code[$i] = ' '
				if ($char -eq '`') { $raw = $false }
				$i += 1
				continue
			}
			# Everything after `//` on this line is comment, including any quote or
			# backtick in it, so the scan stops rather than reading them as literals.
			if (($char -eq '/') -and ($next -eq '/')) {
				$opens = $true
				for ($b = $i; $b -lt $line.Length; $b++) { $code[$b] = ' ' }
				break
			}
			if (($char -eq '/') -and ($next -eq '*')) {
				$opens = $true
				$code[$i] = ' '
				$code[$i + 1] = ' '
				$depth += 1
				$i += 2
				continue
			}
			if ($char -eq '`') { $code[$i] = ' '; $raw = $true; $i += 1; continue }
			if (($char -eq '"') -or ($char -eq "'")) {
				$quote = $char
				$code[$i] = ' '
				$i += 1
				while ($i -lt $line.Length) {
					$code[$i] = ' '
					if ($line[$i] -eq '\') {
						if (($i + 1) -lt $line.Length) { $code[$i + 1] = ' ' }
						$i += 2
						continue
					}
					if ($line[$i] -eq $quote) { $i += 1; break }
					$i += 1
				}
				continue
			}
			$i += 1
		}

		$facts.Add([pscustomobject]@{
				Text    = $line
				Live    = $live
				Comment = $opens
				Code    = (-join $code)
			})
	}

	$script:OdinLineFactMemo[$Text] = $facts.ToArray()
	return $script:OdinLineFactMemo[$Text]
}

# The header of one top-level procedure declaration, read once for the two
# questions that used to be two walks: does a BODY open after it, and does it
# hand anything back.
#
# The body is the load-bearing one, and the reason is that a procedure TYPE is a
# legal top-level declaration with the same first line and no body at all:
#
#   Fault_Says :: proc(fault: Build_Fault) -> string
#
# Every question the three checks ask is a question about a body. A type has no
# length for rule F1, no lines for section 0 to find a comment in, and no call
# site for rule F2's attribute to fail -- and the compiler REFUSES
# @(require_results) on one, so a demand for it there is a build nobody can make
# pass. Recognising a type by "the next column-0 `::` declaration arrives first"
# missed the shape this repository actually writes, a fault-facts signature above
# a `:=` table, because `FAULT :=` is not a `::` declaration; the walk ran on to
# the TABLE's closing brace and handed all three checks a procedure that does not
# exist.
#
# What separates the two is the brace, at DEPTH ZERO: a `{` there opens the body,
# and a `{` inside a parameter default sits inside the parameter list and is
# never at depth zero. The same depth answers the results question, and it has to
# be depth and not a search for two characters -- a parameter that is itself a
# procedure carries its own `->` one level in, so `f :: proc(cb: proc(x: int) ->
# int)` returns nothing at all.
#
# A `where` clause is the one thing that may follow a complete signature before
# the brace, so it is the one continuation this looks for. Without that, a clause
# odinfmt put on its own line would end the header early and the procedure would
# vanish from all three checks -- the silent direction, and the one no build
# failure would ever report.
function Read-OdinProcedureHeader {
	param(
		[Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Facts,
		[Parameter(Mandatory)] [int] $Start
	)

	$depth = 0
	$returns = $false
	$clause = $false

	for ($i = $Start; $i -lt $Facts.Count; $i++) {
		$code = $Facts[$i].Code
		for ($j = 0; $j -lt $code.Length; $j++) {
			$char = $code[$j]
			if ($char -eq '(') { $depth += 1; continue }
			if ($char -eq ')') { $depth -= 1; continue }
			if ($depth -ne 0) { continue }
			if ($char -eq '{') {
				return [pscustomobject]@{ Body = $true; Returns = $returns; End = $i }
			}
			if (($char -eq '-') -and ((($j + 1) -lt $code.Length) -and ($code[$j + 1] -eq '>'))) {
				$returns = $true
				$j += 1
			}
		}

		if ($code -match '\bwhere\b') { $clause = $true }
		if ($depth -gt 0) { continue }
		if ($clause) { continue }
		if ((($i + 1) -lt $Facts.Count) -and ($Facts[$i + 1].Code -match '^\s*where\b')) { continue }
		return [pscustomobject]@{ Body = $false; Returns = $returns; End = $i }
	}
	return [pscustomobject]@{ Body = $false; Returns = $returns; End = $Facts.Count - 1 }
}

# Every top-level procedure in one file, as the half-open span of lines its body
# occupies: the line carrying `::` and the line carrying its closing brace.
#
# Column zero is what makes this readable rather than a parser. Every file the
# check covers has been through odinfmt, so a top-level declaration starts at
# column 0 and its closing brace is a bare `}` there -- which is exactly what
# separates a procedure from the `proc(...) ---` entries inside a foreign block,
# indented one level in. A header with no body (a procedure TYPE) is recognised
# by Read-OdinProcedureHeader above and reported as nothing at all.
#
# Whether it RETURNS comes back on the same range, because it comes off the same
# walk: the brace that ends the header and the arrow before it are two answers to
# one question about where the signature stops. Rule F2 used to ask separately,
# in 31 lines that were this file's lexer with the variables renamed, and the two
# readers duly disagreed -- about the procedure type above, which one of them
# demanded an attribute for and the other measured the length of.
#
# Lines that do not BEGIN in ordinary code are skipped, so a `}` at column 0
# inside a raw string does not end a procedure early. ONE scan, because three
# checks read these boundaries -- rule F1's line limit, section 0's comment ban
# and rule F2's attribute -- and a second copy is two readers that disagree about
# where a procedure ends the first time either is fixed.
#
# What column zero costs is a procedure declared INDENTED -- inside a `when`
# block, or nested in another body. This does not see one at all: not its
# length, and not its comments. Get-OdinHiddenProcedure below closes that from
# the other end by refusing the declaration, so the two checks keep saying
# something true rather than something narrower than they claim.
#
# What is NOT closed is a body that opens and whose column-0 `}` never arrives:
# the walk below breaks with nothing recorded, so the procedure is DROPPED
# rather than refused, and a dropped procedure is the same green as a file that
# never had one. Issue #52 is the refusal, written the way the indented
# declaration is refused above.
#
# The formatter is not what stands between the tree and that shape. It does not
# have to produce it -- it ACCEPTS it. This is an odinfmt fixed point, and
# `odin check` exits 0 over it under the full vet set:
#
#   escapes :: proc() -> bool {
#   	// a comment section 0 bans
#   	return true}
#
# so `escapes` breaks section 0 and rule F2 at once and is invisible to both,
# silently. Long-standing rather than new here: the same shape drops the same
# way on main.
function Get-OdinProcedureRange {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$facts = @(Get-OdinLineFact -Text $Text)
	$found = [System.Collections.Generic.List[object]]::new()
	for ($i = 0; $i -lt $facts.Count; $i++) {
		if (-not $facts[$i].Live) {
			continue
		}
		if ($facts[$i].Text -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b') {
			continue
		}
		# Read before the inner loop's own matches overwrite $Matches.
		$name = $Matches[1]
		$header = Read-OdinProcedureHeader -Facts $facts -Start $i
		if (-not $header.Body) {
			continue
		}

		for ($j = $header.End + 1; $j -lt $facts.Count; $j++) {
			if (-not $facts[$j].Live) {
				continue
			}
			if ($facts[$j].Text -eq '}') {
				$found.Add([pscustomobject]@{ Name = $name; Start = $i; End = $j; Returns = $header.Returns })
				break
			}
			if (($facts[$j].Text -match '^[A-Za-z_][A-Za-z0-9_]*\s*::') -or ($facts[$j].Text -match '^@')) {
				break
			}
		}
	}
	return $found.ToArray()
}

# Every procedure declaration in one file that Get-OdinProcedureRange cannot
# see: one indented, rather than at column 0.
#
# The alternative was a note saying the scan misses them, and a note is what the
# next person reads AFTER the check has been quietly passing over a body for a
# year. Both readers above are anchored at column 0, so the honest way to make
# their answers complete is to refuse the declaration that would make them
# incomplete -- hoist it out of the `when` block, or teach both scans.
#
# The exception is a `foreign` block, whose entries are indented by construction
# and carry no body at all. Tracked by the block rather than by the trailing
# `---`: what makes those entries uninteresting is that nothing can be inside
# them, and that is a property of where they sit.
function Get-OdinHiddenProcedure {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$facts = @(Get-OdinLineFact -Text $Text)
	$found = [System.Collections.Generic.List[object]]::new()
	$foreign = $false
	for ($i = 0; $i -lt $facts.Count; $i++) {
		if (-not $facts[$i].Live) {
			continue
		}
		if ($foreign) {
			if ($facts[$i].Text -eq '}') {
				$foreign = $false
			}
			continue
		}
		if ($facts[$i].Text -match '^foreign\b[^"]*\{\s*$') {
			$foreign = $true
			continue
		}
		if ($facts[$i].Text -match '^\s+([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b') {
			$found.Add([pscustomobject]@{ Name = $Matches[1]; Line = $i + 1 })
		}
	}
	return $found.ToArray()
}

# Every comment inside a procedure body in one file, with the line it sits on.
#
# STRICTLY inside: the header line and the closing brace are excluded, so the
# comment a procedure is allowed -- the one above it, explaining why it exists --
# is not read as one inside it. Reported at the line a comment OPENS on, so a
# block comment spanning ten lines is one finding and not ten.
function Get-OdinBodyComment {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$facts = @(Get-OdinLineFact -Text $Text)
	$found = [System.Collections.Generic.List[object]]::new()
	foreach ($range in @(Get-OdinProcedureRange -Text $Text)) {
		for ($i = $range.Start + 1; $i -lt $range.End; $i++) {
			if (-not $facts[$i].Comment) {
				continue
			}
			$found.Add([pscustomobject]@{
					Name = $range.Name
					Line = $i + 1
					Text = $facts[$i].Text.Trim()
				})
		}
	}
	return $found.ToArray()
}

# Every top-level procedure in one file that hands something back, with whether
# the attribute that makes a dropped answer a build failure sits above it.
#
# The THIRD reader of Get-OdinProcedureRange, after rule F1's line limit and
# section 0's comment ban, and here for the direction the attribute cannot cover
# by itself. `@(require_results)` catches a call site that drops a result, and
# the compiler refuses the attribute on a procedure with no results -- so neither
# of them says anything about the procedure written tomorrow that returns a fault
# and never carries it. That is how the bare ones came to be here (issue #43),
# and it is the same lesson $OdinPackagesWithoutTests records: a rule applied
# once is a snapshot.
#
# Which procedures return is decided by the range reader, on the walk it takes
# anyway. All that is left here is where the attribute sits.
#
# Attributes sit above the declaration, and what may sit BETWEEN them and it is
# the comment a procedure is allowed -- the one saying why it exists. Skipping
# that costs nothing because Code has already blanked it: a comment-only line and
# a blank line are the same empty string here, and neither is an attribute or a
# declaration. Reading Text instead is how this came to report
#
#   @(require_results)
#   // why this exists
#   f :: proc() -> bool { ... }
#
# as bare, in a message telling somebody to put the attribute where it already
# was. Both spellings are accepted for the same reason -- odinfmt rewrites
# `@require_results` to the parenthesised form, but the compiler's own sources
# write the bare one, so a reader that knew only one would be right only about
# files that had been formatted.
function Get-OdinResultProcedure {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$facts = @(Get-OdinLineFact -Text $Text)
	$found = [System.Collections.Generic.List[object]]::new()
	foreach ($range in @(Get-OdinProcedureRange -Text $Text)) {
		if (-not $range.Returns) {
			continue
		}

		$required = $false
		for ($k = $range.Start - 1; $k -ge 0; $k--) {
			$code = $facts[$k].Code
			if ($code -match '^@') {
				if ($code -match '\brequire_results\b') {
					$required = $true
					break
				}
				continue
			}
			if ($code.Trim() -ne '') {
				break
			}
		}

		$found.Add([pscustomobject]@{
				Name     = $range.Name
				Line     = $range.Start + 1
				Required = $required
			})
	}
	return $found.ToArray()
}

# The `#+vet` names one file declares for itself, read off the file tags above
# its `package` clause.
#
# ABOVE the clause and not merely anywhere in the file, because above it is the
# only place the compiler reads one: a `#+vet` line below the clause is a syntax
# error, so a reader that credited it would report a name for a file that does
# not build at all.
#
# Through Get-OdinLineFact like every other reader here, and not over the raw
# lines. What sits above `package` is the file's doc comment --
# docs\reference\winhttp-download.odin's runs to twenty lines -- and a comment
# QUOTING a tag line is exactly what a file explaining this rule would carry.
#
# WHERE among the tags it sits is not read, deliberately. Issue #48 puts
# `#+private` on the first line of every test file and issue #45 adds a second
# vet name; a rule pinning this one to line 1 would have to be re-litigated by
# both, and would be enforcing a habit rather than the property. What makes the
# tag do anything is that it is above the clause, which is what this reads.
function Get-OdinFileVetTag {
	param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

	$names = [System.Collections.Generic.List[string]]::new()
	foreach ($fact in @(Get-OdinLineFact -Text $Text)) {
		$code = $fact.Code.Trim()
		if ($code -match '^package\b') {
			break
		}
		if ($code -notmatch '^#\+vet\b') {
			continue
		}
		foreach ($name in @(($code -replace '^#\+vet\b', '') -split '\s+')) {
			if ($name -ne '') {
				$names.Add($name)
			}
		}
	}
	return $names.ToArray()
}

# Every .odin file the checks cover, refused when discovery finds none.
#
# The refusal is the whole reason this is a procedure. A check that covers zero
# files reports the same green as one that checked everything, and this file had
# written that guard out three times before somebody counted -- once per caller,
# which is once per chance to leave it out of the fourth.
#
# Repository-wide through Get-OdinSource, which is the scope all three checks and
# the formatter ask. Rule F1 learned it the hard way: an audit scoped to src\
# left a spike in docs\reference\ growing to 107 lines with nothing looking
# outside src\, and left body comments there that section 0's ban never saw.
function Get-OdinCheckedSource {
	$sources = @(Get-OdinSource)
	if ($sources.Count -eq 0) {
		throw "no .odin files found under $RepoRoot, so this check would pass having read nothing."
	}
	return $sources
}

# Nothing may be declared where the column-zero scans cannot look.
#
# This is what makes the two verdicts below mean what they say. A message reading
# "N comment(s) inside a procedure body" is a claim about EVERY procedure, and a
# procedure the scan cannot see makes that claim false without ever making it
# look false. Rule F2's verdict is the same claim about the same procedures.
#
# BOTH policies call it, and that is the fix rather than the belt and braces it
# looks like. It used to sit inside the comment policy alone, so rule F2 was
# complete only because build.ps1 happened to call that one first -- an ordering
# nothing stated and nothing checked, which the next edit to build.ps1 would have
# reversed silently. A guarantee that depends on the order of two calls is a
# guarantee held by whoever reads build.ps1 most recently.
function Assert-OdinVisibleProcedure {
	param([Parameter(Mandatory)] [object[]] $Sources)

	$hidden = @()
	foreach ($source in $Sources) {
		foreach ($procedure in @(Get-OdinHiddenProcedure -Text ([System.IO.File]::ReadAllText($source.Path)))) {
			$hidden += "  - $($source.Name):$($procedure.Line) declares $($procedure.Name)"
		}
	}
	if ($hidden.Count -eq 0) {
		return
	}

	throw "$($hidden.Count) procedure(s) declared indented, where none of the three column-zero checks can see them:`n$($hidden -join "`n")`nDeclare it at column 0, or teach Get-OdinProcedureRange to find it."
}

# CLAUDE.md section 0 as a single verdict, for the same caller and the same
# reason Assert-OdinFormatting has one: a rule enforced only at review is a rule
# that reaches main.
function Assert-OdinCommentPolicy {
	$sources = @(Get-OdinCheckedSource)
	Assert-OdinVisibleProcedure -Sources $sources

	$found = @()
	foreach ($source in $sources) {
		foreach ($comment in @(Get-OdinBodyComment -Text ([System.IO.File]::ReadAllText($source.Path)))) {
			$found += "  - $($source.Name):$($comment.Line) in $($comment.Name): $($comment.Text)"
		}
	}
	if ($found.Count -eq 0) {
		return
	}

	throw "$($found.Count) comment(s) inside a procedure body (CLAUDE.md section 0):`n$($found -join "`n")`nSay it in the code, or say why above the procedure."
}

# CLAUDE.md rule F2 as a single verdict, beside section 0's and for the reason
# that one is here at all.
#
# It does NOT fail when it finds no RETURNING procedure, and that is where the
# deny-by-default habit stops. Zero files means discovery is broken; zero
# returning procedures is an ordinary small program -- `main :: proc()` prints a
# line and hands nothing back, and every build fixture in scripts\selftest.ps1 is
# exactly that. Written as a "measured nothing" guard first, this refused six of
# them, and the refusal was correct about the arithmetic and wrong about the
# claim. The guard against a vacuous pass belongs where the tree being read is
# known to carry hundreds, which is the selftest case and not here.
function Assert-OdinResultPolicy {
	$sources = @(Get-OdinCheckedSource)
	Assert-OdinVisibleProcedure -Sources $sources

	$bare = @()
	foreach ($source in $sources) {
		$text = [System.IO.File]::ReadAllText($source.Path)
		foreach ($procedure in @(Get-OdinResultProcedure -Text $text)) {
			if (-not $procedure.Required) {
				$bare += "  - $($source.Name):$($procedure.Line) $($procedure.Name)"
			}
		}
	}
	if ($bare.Count -eq 0) {
		return
	}

	throw "$($bare.Count) procedure(s) hand back an answer nothing obliges the caller to read (CLAUDE.md rule F2):`n$($bare -join "`n")`nPut @(require_results) above the declaration. A caller that means to throw the answer away writes `_ = f(...)`."
}

# CLAUDE.md rule M2 as a single verdict, beside section 0's and rule F2's, and
# here for the reason all three are: a rule enforced only at review is a rule that
# reaches main.
#
# ABSENCE is the whole subject, and it is the only failure this has to cover. A
# misspelled name is `Syntax Error: Invalid vet flag name` and a tag below the
# package clause is `Lines starting with #+ (file tags) are only allowed before
# the package line` -- both stop the build on their own, naming the file. A tag
# that was never written stops nothing: the file compiles, and every call in it
# that takes its allocator from the context goes unread, because the tag applies
# to the FILE that carries it and to nothing else.
#
# So this is a ratchet and not a sweep. It changes nothing about a tree that
# already obeys the rule; what it refuses is the file added tomorrow, which is
# the one direction 65 hand-written lines rot in.
function Assert-OdinVetTagPolicy {
	$sources = @(Get-OdinCheckedSource)

	$missing = @()
	foreach ($source in $sources) {
		$declared = @(Get-OdinFileVetTag -Text ([System.IO.File]::ReadAllText($source.Path)))
		foreach ($tag in $OdinFileVetTags) {
			# Case-SENSITIVE, the way the compiler reads the name. A spelling it
			# would refuse is not a spelling this may accept.
			if ($declared -cnotcontains $tag) {
				$missing += "  - $($source.Name) does not declare $tag"
			}
		}
	}
	if ($missing.Count -eq 0) {
		return
	}

	$line = "#+vet $($OdinFileVetTags -join ' ')"
	throw "$($missing.Count) file(s) do not declare a +vet tag every .odin file carries (CLAUDE.md rule M2):`n$($missing -join "`n")`nPut ``$line`` above the package clause. The tag is read per FILE: an untagged one compiles with its implicit allocators never looked at, whatever its siblings carry."
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
