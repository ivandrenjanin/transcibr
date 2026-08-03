# Shared build configuration, dot-sourced by build.ps1 and test.ps1.
#
# The vet set lives here once. Held separately, the two commands drift, and
# code that compiles under one starts failing under the other.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcRoot = Join-Path $RepoRoot 'src'
$BuildRoot = Join-Path $RepoRoot 'build'

# The full vet set from CLAUDE.md rule S1. Every build and test invocation
# passes all of it, warnings included.
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

# Odin is not on PATH on the development machine, so fall back to the default
# install location rather than making every contributor edit their PATH. Set
# $env:ODIN to override.
function Resolve-OdinCompiler {
	if ($env:ODIN) {
		if (-not (Test-Path -LiteralPath $env:ODIN)) {
			throw "ODIN is set to '$env:ODIN' but no file is there."
		}
		return (Resolve-Path -LiteralPath $env:ODIN).Path
	}

	$onPath = Get-Command 'odin' -CommandType Application -ErrorAction SilentlyContinue
	if ($onPath) {
		return $onPath.Source
	}

	$fallback = 'C:\Odin\dist\odin.exe'
	if (Test-Path -LiteralPath $fallback) {
		return $fallback
	}

	throw "Cannot find the Odin compiler. Put 'odin' on PATH or set `$env:ODIN to its full path."
}

# Every directory under src/ holding at least one .odin file is a package.
# Discovered rather than listed, so a new package cannot be added without the
# test sweep picking it up.
function Get-OdinPackage {
	$roots = @(Get-Item -LiteralPath $SrcRoot) + @(Get-ChildItem -LiteralPath $SrcRoot -Recurse -Directory)
	$packages = @()
	foreach ($dir in $roots) {
		$odinFiles = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.odin' -File -ErrorAction SilentlyContinue
		if ($odinFiles) {
			$packages += $dir.FullName
		}
	}
	return $packages
}
