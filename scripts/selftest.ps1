# Self-test for the build and test commands.
#
#   .\scripts\selftest.ps1
#
# The sweep in test.ps1 is the one script whose failure mode is silence: every
# bug it has shipped so far reported success having run nothing. Checking it by
# hand is exactly the discipline that let those bugs through, so the checks live
# here instead.
#
# Each case plants a throwaway repository -- a copy of scripts\ next to a
# hand-built src\ -- runs the real test.ps1 inside it as a separate process, and
# asserts on the exit code and the output. Nothing here touches the real src\.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "transcibr-selftest-$PID"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Failures = @()
$script:Skips = @()
$script:Passes = 0

# ---------------------------------------------------------------- fixtures --

function New-FixtureRepo {
	param([Parameter(Mandatory)] [string] $Name)

	$root = Join-Path $FixtureRoot $Name
	if (Test-Path -LiteralPath $root) {
		Remove-Item -LiteralPath $root -Recurse -Force
	}
	$scripts = Join-Path $root 'scripts'
	New-Item -ItemType Directory -Path $scripts -Force | Out-Null
	New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
	Copy-Item -Path (Join-Path $ScriptRoot 'common.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'test.ps1') -Destination $scripts -Force
	Copy-Item -Path (Join-Path $ScriptRoot 'build.ps1') -Destination $scripts -Force
	return $root
}

# Odin source, written ASCII/no-BOM with tab indentation so the fixtures pass
# the same vet set as the real packages.
function Add-FixturePackage {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [ValidateSet('passing', 'failing', 'leaking', 'none')] [string] $Test,
		[switch] $Hidden
	)

	$dir = Join-Path (Join-Path $RepoRoot 'src') $Name
	New-Item -ItemType Directory -Path $dir -Force | Out-Null

	$body = switch ($Test) {
		'passing' { "import `"core:testing`"`n`n@(test)`n${Name}_passes :: proc(t: ^testing.T) {`n`ttesting.expect(t, true)`n}`n" }
		'failing' { "import `"core:testing`"`n`n@(test)`n${Name}_fails :: proc(t: ^testing.T) {`n`ttesting.expect(t, false, `"deliberate failure`")`n}`n" }
		'leaking' { "import `"core:testing`"`n`n@(test)`n${Name}_leaks :: proc(t: ^testing.T) {`n`tleaked := make([]u8, 8, context.allocator)`n`ttesting.expect(t, len(leaked) == 8)`n}`n" }
		'none' { "${Name}_CONSTANT :: 1`n" }
	}
	$source = "package $Name`n`n$body"
	[System.IO.File]::WriteAllText((Join-Path $dir "$Name.odin"), $source, $Utf8NoBom)

	if ($Hidden) {
		$item = Get-Item -LiteralPath $dir -Force
		$item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
	}
	return $dir
}

# A separate process, so the child's Set-StrictMode, exit code and $LASTEXITCODE
# are the real ones a developer sees rather than this script's.
function Invoke-FixtureScript {
	param(
		[Parameter(Mandatory)] [string] $RepoRoot,
		[Parameter(Mandatory)] [string] $Script,
		# Have the CHILD merge its own streams with 2>&1, the way a caller
		# piping the script's whole output would. Redirection at the process
		# level, as below, does not exercise that path at all.
		[switch] $MergeStreams
	)

	$outFile = Join-Path $FixtureRoot "out-$([System.Guid]::NewGuid().ToString('N')).log"
	$errFile = [System.IO.Path]::ChangeExtension($outFile, '.err.log')
	$scriptPath = Join-Path (Join-Path $RepoRoot 'scripts') $Script

	$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
	if ($MergeStreams) {
		$arguments += @('-Command', "`"& '$scriptPath' 2>&1 | Out-Null; exit `$LASTEXITCODE`"")
	}
	else {
		$arguments += @('-File', "`"$scriptPath`"")
	}

	$process = Start-Process -FilePath 'powershell.exe' `
		-ArgumentList $arguments `
		-WorkingDirectory $RepoRoot -NoNewWindow -Wait -PassThru `
		-RedirectStandardOutput $outFile -RedirectStandardError $errFile

	$text = ''
	foreach ($file in @($outFile, $errFile)) {
		if (Test-Path -LiteralPath $file) {
			$text += (Get-Content -LiteralPath $file -Raw)
			Remove-Item -LiteralPath $file -Force
		}
	}
	return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $text }
}

# -------------------------------------------------------------- assertions --

function Test-Case {
	param(
		[Parameter(Mandatory)] [string] $Name,
		[Parameter(Mandatory)] [scriptblock] $Body
	)

	Write-Host ''
	Write-Host "--- $Name" -ForegroundColor Cyan
	try {
		& $Body
		Write-Host "    PASS" -ForegroundColor Green
		$script:Passes += 1
	}
	catch [System.Management.Automation.ItemNotFoundException] {
		# Thrown by Skip-Case only: a case whose SETUP the environment refused,
		# which is not the same as the case failing. Reported, never silent.
		Write-Host "    SKIP: $($_.Exception.Message)" -ForegroundColor Yellow
		$script:Skips += "$Name -- $($_.Exception.Message)"
	}
	catch {
		Write-Host "    FAIL: $($_.Exception.Message)" -ForegroundColor Red
		$script:Failures += "$Name -- $($_.Exception.Message)"
	}
}

# A case this machine cannot set up. Distinct from a failure, and loud either
# way -- the summary lists skips even when everything else passes.
function Skip-Case {
	param([Parameter(Mandatory)] [string] $Reason)
	throw (New-Object System.Management.Automation.ItemNotFoundException($Reason))
}

function Assert-ExitCode {
	param(
		[Parameter(Mandatory)] $Result,
		[Parameter(Mandatory)] [ValidateSet('zero', 'nonzero')] [string] $Expected
	)

	$isZero = ($Result.ExitCode -eq 0)
	if (($Expected -eq 'zero') -and (-not $isZero)) {
		throw "expected exit 0, got $($Result.ExitCode).`n$($Result.Output)"
	}
	if (($Expected -eq 'nonzero') -and $isZero) {
		throw "expected a non-zero exit, got 0.`n$($Result.Output)"
	}
}

function Assert-Output {
	param(
		[Parameter(Mandatory)] $Result,
		[Parameter(Mandatory)] [string] $Pattern
	)

	if ($Result.Output -notmatch $Pattern) {
		throw "output did not match /$Pattern/.`n$($Result.Output)"
	}
}

# ------------------------------------------------------------------- cases --

New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
Write-Host "Fixtures: $FixtureRoot"

Test-Case 'a single package with zero tests fails loudly' {
	$repo = New-FixtureRepo 'one-package'
	Add-FixturePackage -RepoRoot $repo -Name 'solo' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'no packages at all fails loudly' {
	$repo = New-FixtureRepo 'no-packages'
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'a repository path containing a space still runs its tests' {
	$repo = New-FixtureRepo 'path with space'
	Add-FixturePackage -RepoRoot $repo -Name 'spaced' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'zero'
	Assert-Output -Result $result -Pattern 'All 1 tests? passed'
}

Test-Case 'a passing sweep survives a caller that merges the output streams' {
	$repo = New-FixtureRepo 'merged-streams'
	Add-FixturePackage -RepoRoot $repo -Name 'merged' -Test 'passing' | Out-Null
	# `2>&1` in the caller makes PowerShell wrap the runner's stderr log in
	# ErrorRecords, and the sweep runs under $ErrorActionPreference = 'Stop':
	# without care the first INFO line of a good run terminates the script.
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1' -MergeStreams
	Assert-ExitCode -Result $result -Expected 'zero'
	Assert-Output -Result $result -Pattern 'All 1 tests? passed'
}

Test-Case 'a hidden package is discovered, not skipped' {
	$repo = New-FixtureRepo 'hidden-package'
	Add-FixturePackage -RepoRoot $repo -Name 'visible' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'concealed' -Test 'failing' -Hidden | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'concealed'
}

Test-Case 'an unreadable directory fails discovery rather than shortening it' {
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
		Assert-ExitCode -Result $result -Expected 'nonzero'
		Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
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
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'beta'
}

Test-Case 'a package declared test-less is allowed to have none' {
	$repo = New-FixtureRepo 'declared-testless'
	Add-FixturePackage -RepoRoot $repo -Name 'alpha' -Test 'passing' | Out-Null
	Add-FixturePackage -RepoRoot $repo -Name 'cli' -Test 'none' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'zero'
}

Test-Case 'a package declared test-less that grows tests fails the sweep' {
	$repo = New-FixtureRepo 'stale-declaration'
	Add-FixturePackage -RepoRoot $repo -Name 'cli' -Test 'passing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'cli'
}

Test-Case 'a deliberately failing test fails the sweep' {
	$repo = New-FixtureRepo 'failing-test'
	Add-FixturePackage -RepoRoot $repo -Name 'broken' -Test 'failing' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'TEST COMMAND FAILED'
}

Test-Case 'a test that leaks its returned slice fails rather than warns' {
	$repo = New-FixtureRepo 'leaking-test'
	Add-FixturePackage -RepoRoot $repo -Name 'leaky' -Test 'leaking' | Out-Null
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
}

Test-Case 'a package that does not compile fails the sweep' {
	$repo = New-FixtureRepo 'broken-orphan'
	Add-FixturePackage -RepoRoot $repo -Name 'good' -Test 'passing' | Out-Null
	$orphan = Add-FixturePackage -RepoRoot $repo -Name 'orphan' -Test 'passing'
	[System.IO.File]::WriteAllText((Join-Path $orphan 'orphan.odin'), "package orphan`n`nthis is not Odin`n", $Utf8NoBom)
	$result = Invoke-FixtureScript -RepoRoot $repo -Script 'test.ps1'
	Assert-ExitCode -Result $result -Expected 'nonzero'
	Assert-Output -Result $result -Pattern 'orphan'
}

# ----------------------------------------------------------------- summary --

if (Test-Path -LiteralPath $FixtureRoot) {
	Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
}

Write-Host ''
Write-Host '========================================'
Write-Host "Cases passed: $script:Passes"

if ($script:Skips.Count -gt 0) {
	Write-Host ''
	Write-Host "Cases skipped: $($script:Skips.Count)" -ForegroundColor Yellow
	foreach ($skip in $script:Skips) {
		Write-Host "  - $skip" -ForegroundColor Yellow
	}
}

if ($script:Failures.Count -gt 0) {
	Write-Host ''
	Write-Host "SELFTEST FAILED in $($script:Failures.Count) case(s):" -ForegroundColor Red
	foreach ($failure in $script:Failures) {
		Write-Host "  - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host ''
Write-Host "All $script:Passes self-test cases passed." -ForegroundColor Green
exit 0
