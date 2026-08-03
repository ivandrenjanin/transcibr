# Install one pinned tool of this toolchain from its release zip.
#
#   .\scripts\install-pinned-tool.ps1 -Tool odin
#   .\scripts\install-pinned-tool.ps1 -Tool odinfmt
#
# Written for CI and runnable anywhere. Both tools arrive the same way: download
# a TAGGED release zip, extract it, find the executable inside by pattern, and
# name the path in the environment variable scripts\common.ps1 already resolves
# from -- so CI runs the developer's commands as-is rather than a second set of
# its own. .github\workflows\ci.yml held those twenty-odd lines twice, once per
# tool, differing in four values; this is them once, and the four values are the
# table below.
#
# Every pin comes from scripts\common.ps1 and none is spelled here. A tag copied
# into a workflow is a tag that drifts from the version string the scripts then
# check, and the failure reads as "the compiler is wrong" rather than "the two
# copies disagree".
#
# The executable is resolved by PATTERN and never by a path inside the archive:
# the ols member is named for its target triple, and a layout assumed here is a
# second thing to keep in step with upstream. Matching NOTHING is a failure and
# not an empty result -- and a wrong match dies immediately afterwards, on the
# version string or the SHA-256 the scripts check on every resolve.

[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidateSet('odin', 'odinfmt')]
	[string] $Tool,

	# Where the archive is unpacked. The CI runner's own scratch directory by
	# default, which is what makes this runnable locally without one.
	[string] $Destination = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

trap {
	Write-Host ''
	Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
	exit 1
}

# The four values the two installs differ in, and nothing else.
$plan = @{
	'odin'    = [pscustomobject]@{
		Variable = 'ODIN'
		Asset    = "odin-windows-amd64-$OdinReleaseTag.zip"
		Url      = "https://github.com/odin-lang/Odin/releases/download/$OdinReleaseTag/odin-windows-amd64-$OdinReleaseTag.zip"
		Pattern  = 'odin.exe'
		Pinned   = "$OdinReleaseTag, which reports $OdinVersionPin"
	}
	'odinfmt' = [pscustomobject]@{
		Variable = 'ODINFMT'
		Asset    = $OdinfmtAsset
		Url      = "https://github.com/DanielGavin/ols/releases/download/$OdinfmtReleaseTag/$OdinfmtAsset"
		Pattern  = 'odinfmt*.exe'
		Pinned   = "ols $OdinfmtReleaseTag, which must hash to $OdinfmtSha256"
	}
}[$Tool]

if ($Destination -eq '') {
	if (-not $env:RUNNER_TEMP) {
		throw 'no RUNNER_TEMP to unpack into. Pass -Destination when running this outside CI.'
	}
	$Destination = $env:RUNNER_TEMP
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

Write-Host "Pinned to $($plan.Pinned)"
$zip = Join-Path $Destination $plan.Asset
$unpacked = Join-Path $Destination "$Tool-unpacked"

Write-Host "Downloading $($plan.Url)"
Invoke-WebRequest -Uri $plan.Url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $unpacked -Force

$exe = Get-ChildItem -Path $unpacked -Recurse -Filter $plan.Pattern -File | Select-Object -First 1
if (-not $exe) {
	throw "no file matching $($plan.Pattern) under $unpacked after extracting $($plan.Asset)."
}

# Named in the environment the scripts read, which is the whole integration.
# Written to GITHUB_ENV where there is one, so the value outlives this step;
# set on this process either way, so a local run leaves a usable shell.
Set-Item -LiteralPath "env:$($plan.Variable)" -Value $exe.FullName
if ($env:GITHUB_ENV) {
	"$($plan.Variable)=$($exe.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}

# Proof the pin holds, from the resolver the build and test commands use -- so a
# mismatch is reported by this step rather than three steps later, and reported
# in the words the scripts themselves use. Under $env:CI both resolvers refuse a
# mismatch outright instead of warning.
if ($Tool -eq 'odin') {
	$reported = Read-NativeOutput -Command $exe.FullName -Arguments @('version') -TimeoutSeconds $OdinCommandTimeoutSeconds
	Write-Host "$($exe.FullName) says: $($reported.Output)"
	Resolve-OdinCompiler | Out-Null
}
else {
	Write-Host "$($exe.FullName) hashes to $(Get-FileSha256 -Path $exe.FullName)"
	Resolve-OdinFormatter | Out-Null
}

Write-Host "-> $($plan.Variable)=$($exe.FullName)" -ForegroundColor Green
exit 0
