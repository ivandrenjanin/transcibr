# The build command.
#
#   .\scripts\build.ps1
#
# Produces build\transcibr-cli.exe, a console-subsystem binary (ADR-0004),
# under the full vet set with warnings as errors.

[CmdletBinding()]
param(
	[ValidateSet('debug', 'release')]
	[string] $Configuration = 'debug'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$odin = Resolve-OdinCompiler
Write-Host "Odin:   $odin"

if (-not (Test-Path -LiteralPath $BuildRoot)) {
	New-Item -ItemType Directory -Path $BuildRoot | Out-Null
}

$out = Join-Path $BuildRoot 'transcibr-cli.exe'

# -subsystem:console is stated rather than assumed. It is already the default
# for a package named main, but the GUI binary this repository will also carry
# (ADR-0004) differs from this one by exactly that flag, so neither is implicit.
$arguments = @(
	'build'
	(Join-Path $SrcRoot 'cli')
	$OdinCollection
	"-out:$out"
	'-subsystem:console'
) + $OdinVetFlags

if ($Configuration -eq 'release') {
	$arguments += '-o:speed'
}

Write-Host "Build:  $Configuration -> $out"
Write-Host ''

& $odin @arguments
if ($LASTEXITCODE -ne 0) {
	Write-Host ''
	Write-Host "BUILD FAILED (odin exited $LASTEXITCODE)" -ForegroundColor Red
	exit 1
}

Write-Host ''
Write-Host "Built $out" -ForegroundColor Green
