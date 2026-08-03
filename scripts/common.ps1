# Shared build configuration, dot-sourced by build.ps1, test.ps1, selftest.ps1
# and the workflow in .github/workflows/ci.yml.
#
# The vet set, the compiler pin, the list of binaries and the list of packages
# expected to hold no tests all live here once. Held separately, the commands
# drift, and code that compiles under one starts failing under the other.

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

# The wall-clock ceiling on one `odin` invocation, in seconds.
#
# Nothing in the toolchain has one of its own. `odin test` builds a test
# executable and then RUNS it, and that runner hangs outright when two or more
# tests assert concurrently: the Windows signal handler records into a single
# global slot and returns EXCEPTION_CONTINUE_SEARCH, so the faulting thread
# races a main loop that must TerminateThread it, and a second concurrent
# assertion overwrites the slot while TerminateThread abandons the locks of a
# thread killed mid-log. One asserting test fails cleanly; two hang or crash,
# and -define:ODIN_TEST_THREADS=1 makes the hang DETERMINISTIC rather than
# mitigating it. See the cases in scripts\selftest.ps1 that pin this.
#
# Assertions are the failure mode this repository's whole design rests on
# (CLAUDE.md section 1), so a sweep that waits forever for one is a developer's
# terminal that never comes back and a CI job that burns the platform's
# six-hour default before saying anything.
#
# Ten minutes, not one: this repository's whole sweep takes seconds, but a cold
# CI runner compiling from an empty cache is exactly the run that must not be
# killed for being slow. The ceiling exists to bound a HANG, not to police
# speed. scripts\selftest.ps1 passes its own, far shorter, because it plants
# packages built to hang and cannot wait ten minutes to find out that they did.
$OdinCommandTimeoutSeconds = 600

# The compiler this repository is pinned to, in its two spellings: the release
# tag CI downloads, and the string that release's `odin version` prints. They
# do not resemble each other and there is no deriving one from the other, so
# both live here and CI dot-sources this file for the tag rather than keeping
# a second copy in the workflow. One edit moves the pin.
$OdinReleaseTag = 'dev-2026-07a'
$OdinVersionPin = 'dev-2026-07-nightly:819fdc7'

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

# Odin is not on PATH on the development machine, so fall back to the default
# install location rather than making every contributor edit their PATH. Set
# $env:ODIN to override. This is the only copy of the fallback path.
function Resolve-OdinCompiler {
	$odin = $null
	if ($env:ODIN) {
		if (-not (Test-Path -LiteralPath $env:ODIN)) {
			throw "ODIN is set to '$env:ODIN' but no file is there."
		}
		$odin = (Resolve-Path -LiteralPath $env:ODIN).Path
	}
	else {
		$onPath = Get-Command 'odin' -CommandType Application -ErrorAction SilentlyContinue
		if ($onPath) {
			$odin = $onPath.Source
		}
		else {
			$fallback = 'C:\Odin\dist\odin.exe'
			if (-not (Test-Path -LiteralPath $fallback)) {
				throw "Cannot find the Odin compiler. Put 'odin' on PATH or set `$env:ODIN to its full path."
			}
			$odin = $fallback
		}
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

	$quoted = New-Object System.Text.StringBuilder
	[void] $quoted.Append('"')
	$slashes = 0
	foreach ($char in $Value.ToCharArray()) {
		if ($char -eq '\') {
			$slashes += 1
			continue
		}
		if ($char -eq '"') {
			[void] $quoted.Append('\', $slashes * 2 + 1)
		}
		else {
			[void] $quoted.Append('\', $slashes)
		}
		$slashes = 0
		[void] $quoted.Append($char)
	}
	[void] $quoted.Append('\', $slashes * 2)
	[void] $quoted.Append('"')
	return $quoted.ToString()
}

# Run a native command under a wall-clock ceiling, letting its output through to
# the console untouched. Returns the exit code and whether the ceiling was hit.
#
# STARTED rather than invoked with `&`, because a synchronous native call cannot
# be interrupted and nothing in the toolchain has a ceiling of its own -- see
# $OdinCommandTimeoutSeconds for what hangs and why it matters.
#
# The child inherits this process's streams, so the runner's log still reaches
# the console as it happens. It never enters the PowerShell pipeline, which is
# what makes returning a value safe here where the `&` form's return would have
# been indistinguishable from the command's own output. That also settles the
# $ErrorActionPreference trap the `&` form carried: the test runner writes its
# entire log to stderr, and a caller that merged the streams -- `.\scripts\test.ps1
# 2>&1`, or `*>` to a file -- had PowerShell wrap every one of those lines in an
# ErrorRecord, turning the first INFO line of a good run into a terminating
# error under 'Stop'. PowerShell no longer sees those lines at all.
function Invoke-NativeCommand {
	param(
		[Parameter(Mandatory)] [string] $Command,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments,
		[Parameter(Mandatory)] [ValidateRange(1, 86400)] [int] $TimeoutSeconds
	)

	$ErrorActionPreference = 'Continue'
	if ($Arguments.Count -eq 0) {
		$started = Start-Process -FilePath $Command -NoNewWindow -PassThru
	}
	else {
		$line = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' ')
		$started = Start-Process -FilePath $Command -ArgumentList $line -NoNewWindow -PassThru
	}

	# Touching .Handle makes the Process object cache the native handle. Without
	# it .ExitCode reads back empty once the child is gone, and a perfectly good
	# run reports no verdict at all.
	$null = $started.Handle

	if ($started.WaitForExit($TimeoutSeconds * 1000)) {
		return [pscustomobject]@{ ExitCode = $started.ExitCode; TimedOut = $false }
	}

	Stop-ProcessTree -Id $started.Id
	$code = -1
	if ($started.WaitForExit(30000)) {
		$code = $started.ExitCode
	}
	return [pscustomobject]@{ ExitCode = $code; TimedOut = $true }
}

# The same call with the output CAPTURED instead of passed through, for the two
# places that need to read what a program printed: the version check and the
# build's smoke test.
function Read-NativeOutput {
	param(
		[Parameter(Mandatory)] [string] $Command,
		[Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments
	)

	$ErrorActionPreference = 'Continue'
	$text = (& $Command @Arguments | Out-String)
	return [pscustomobject]@{ Output = $text.Trim(); ExitCode = $LASTEXITCODE }
}

# The pin: refused in CI, warned about anywhere else.
#
# An unpinned toolchain turns an upstream change into a build failure on an
# unrelated commit and makes "it passed yesterday" unanswerable, so the shared
# answer -- what CI says about a branch -- comes from the pinned compiler and
# nothing else.
#
# A hard local refusal buys nothing on top of that and costs a great deal. The
# first upstream retag, or the first contributor whose nightly is a week off,
# makes the repository unbuildable and untestable for them until the pin moves
# -- and the warning already tells them how, while CI still catches a change
# that only compiles on their compiler.
function Confirm-OdinVersion {
	param([Parameter(Mandatory)] [string] $Odin)

	$reported = Read-NativeOutput -Command $Odin -Arguments @('version')
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

	if ($env:CI) {
		throw "$mismatch`nCI runs the pinned compiler and nothing else. $remedy"
	}

	Write-Warning "$mismatch`nContinuing on this one. CI will not: anything that builds here and not on the pinned compiler fails there instead. $remedy"
}

# The src-relative name of a package directory, forward-slashed: `version`,
# `cli`, `net/winhttp`. Used as the sweep's label and as the key the test-less
# list is matched against.
#
# Guarded rather than a bare Substring: a subst drive, a UNC path or a
# junctioned checkout can hand back a path that does not share a prefix with
# $SrcRoot at all, and trimming a length off that yields a garbled label or an
# exception. Showing the whole path is the honest answer in that case.
function Get-OdinPackageName {
	param([Parameter(Mandatory)] [string] $Path)

	$full = [System.IO.Path]::GetFullPath($Path)
	$root = $SrcRoot.TrimEnd('\', '/')
	if ($full.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
		return 'src'
	}

	$prefix = $root + [System.IO.Path]::DirectorySeparatorChar
	if ($full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $full.Substring($prefix.Length).Replace('\', '/')
	}

	return $full
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
	$sources = Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force -ErrorAction Stop |
		Where-Object { $_.Extension -eq '.odin' }

	$directories = @($sources | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)

	$packages = @()
	foreach ($directory in $directories) {
		$packages += [pscustomobject]@{
			Path = $directory
			Name = Get-OdinPackageName -Path $directory
		}
	}
	return $packages
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
	param([Parameter(Mandatory)] [string] $Root)

	$cutoff = (Get-Date).AddDays(-1)
	Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue |
		Where-Object { $_.LastWriteTime -lt $cutoff } |
		Remove-Item -Force -ErrorAction SilentlyContinue
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
