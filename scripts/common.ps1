# Shared build configuration, dot-sourced by build.ps1, test.ps1 and selftest.ps1.
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

# The compiler this repository is pinned to, exactly as `odin version` reports
# it. Keep in step with ODIN_RELEASE in .github/workflows/ci.yml: the tagged
# release dev-2026-07a reports this string. A pin nothing checks is a comment,
# so Resolve-OdinCompiler refuses a compiler that reports anything else.
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

	Assert-OdinVersion -Odin $odin
	return $odin
}

# The pin, enforced. An unpinned toolchain turns an upstream change into a
# build failure on an unrelated commit and makes "it passed yesterday"
# unanswerable -- which is just as true locally as in CI.
function Assert-OdinVersion {
	param([Parameter(Mandatory)] [string] $Odin)

	$reported = (& $Odin version | Out-String).Trim()
	if ($LASTEXITCODE -ne 0) {
		throw "'$Odin version' exited $LASTEXITCODE."
	}

	$match = [regex]::Match($reported, 'version\s+(\S+)')
	if (-not $match.Success) {
		throw "Cannot read a version out of '$reported'."
	}

	$found = $match.Groups[1].Value
	if ($found -ne $OdinVersionPin) {
		throw @"
Odin version mismatch.
  expected: $OdinVersionPin
  found:    $found ($Odin)
The pin lives in scripts\common.ps1 (`$OdinVersionPin) and .github\workflows\ci.yml
(ODIN_RELEASE). Change both together, or point `$env:ODIN at the pinned compiler.
"@
	}
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

# A directory guaranteed to exist and to contain no space, for `odin test` to
# write its test executable into.
#
# `odin test` builds a test binary and then runs it, and the command line it
# builds to do that is not quoted: any space in the executable's path is
# re-parsed as an argument separator and the compiler exits -1 with
# "Unknown argument encountered '<second word>'". The default output path is
# derived from the working directory, so a checkout under `C:\Users\John
# Smith\` breaks the sweep before a single test runs -- and CI never sees it,
# because a runner's D:\a\... path has no spaces. `odin build` is unaffected.
#
# The 8.3 short name is the escape: `John Smith` becomes `JOHNSM~1`. It is not
# guaranteed to exist (8.3 generation can be turned off per volume), so the
# result is checked rather than assumed.
function Get-SpaceFreeDirectory {
	param([Parameter(Mandatory)] [string] $Path)

	New-Item -ItemType Directory -Path $Path -Force | Out-Null
	if ($Path -notmatch ' ') {
		return $Path
	}

	$fso = New-Object -ComObject Scripting.FileSystemObject
	$short = $fso.GetFolder($Path).ShortPath
	if ($short -match ' ') {
		throw @"
$Path contains a space and has no 8.3 short name to fall back on, so `odin test`
cannot write its test executable anywhere it can then run. Either check the
repository out under a path without spaces, or re-enable 8.3 name generation on
this volume (fsutil 8dot3name set 0).
"@
	}
	return $short
}

# The subsystem recorded in a PE image's optional header. Reading the header is
# the only check that actually proves ADR-0004's console/GUI split; running the
# binary and watching it print proves only that it runs.
function Get-PeSubsystem {
	param([Parameter(Mandatory)] [string] $Path)

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

	return [System.BitConverter]::ToUInt16($bytes, $subsystemOffset)
}

function Assert-PeSubsystem {
	param(
		[Parameter(Mandatory)] [string] $Path,
		[Parameter(Mandatory)] [string] $Subsystem
	)

	if (-not $PeSubsystemCodes.ContainsKey($Subsystem)) {
		throw "Unknown subsystem '$Subsystem'; expected one of: $($PeSubsystemCodes.Keys -join ', ')."
	}

	$expected = $PeSubsystemCodes[$Subsystem]
	$found = Get-PeSubsystem -Path $Path
	if ($found -ne $expected) {
		throw "$Path is subsystem $found, expected $expected ($Subsystem)."
	}
}
