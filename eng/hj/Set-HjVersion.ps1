#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Set')]
param (
    [Parameter(ParameterSetName = 'Set', Mandatory = $true, Position = 0)]
    [string]$Version,

    [Parameter(ParameterSetName = 'Revert', Mandatory = $true)]
    [switch]$Revert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$gitExe = if ($gitCmd) { $gitCmd.Source } else { 'git' }

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$cargoTomlPath = Join-Path $repoRoot "Cargo.toml"
$cargoLockPath = Join-Path $repoRoot "Cargo.lock"

if (-not (Test-Path $cargoTomlPath)) {
    throw "Cargo.toml not found at '$cargoTomlPath'"
}
if (-not (Test-Path $cargoLockPath)) {
    throw "Cargo.lock not found at '$cargoLockPath'"
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ($Revert) {
    Write-Host "Reverting Cargo.toml and Cargo.lock to repository state..." -ForegroundColor Cyan
    & $gitExe -C $repoRoot checkout -- Cargo.toml Cargo.lock
    if ($LASTEXITCODE -ne 0) {
        throw "git checkout -- Cargo.toml Cargo.lock failed with exit code $LASTEXITCODE"
    }

    & $gitExe -C $repoRoot diff --exit-code -- Cargo.toml Cargo.lock
    if ($LASTEXITCODE -ne 0) {
        throw "Working tree diff detected after restoring Cargo.toml and Cargo.lock."
    }

    Write-Host "Successfully restored Cargo.toml and Cargo.lock byte-identically." -ForegroundColor Green
    return
}

# ParameterSet: Set
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Version parameter must not be empty."
}

Write-Host "Stamping version '$Version' into Cargo.toml and Cargo.lock..." -ForegroundColor Cyan

# 1. Update Cargo.toml [package] version only (leaving workspace/dependency versions intact)
$tomlContent = [System.IO.File]::ReadAllText($cargoTomlPath, [System.Text.Encoding]::UTF8)
if ($tomlContent -notmatch '(?m)^\s*version\s*=\s*"[^"]+"') {
    throw "Could not locate [package] version in '$cargoTomlPath'"
}

$newTomlContent = [regex]::Replace($tomlContent, '(?m)^(\s*version\s*=\s*)"[^"]+"', "`${1}`"$Version`"", 1)
[System.IO.File]::WriteAllText($cargoTomlPath, $newTomlContent, $utf8NoBom)
Write-Host "  Updated Cargo.toml ([package] version = `"$Version`")" -ForegroundColor DarkGray

# 2. Update Cargo.lock gitui package entry only
$lockContent = [System.IO.File]::ReadAllText($cargoLockPath, [System.Text.Encoding]::UTF8)
$lockPattern = '(?m)(name\s*=\s*"gitui"\s*\r?\n\s*version\s*=\s*)"[^"]+"'
if ($lockContent -notmatch $lockPattern) {
    throw "Could not locate [[package]] name = `"gitui`" version in '$cargoLockPath'"
}

$newLockContent = [regex]::Replace($lockContent, $lockPattern, "`${1}`"$Version`"", 1)
[System.IO.File]::WriteAllText($cargoLockPath, $newLockContent, $utf8NoBom)
Write-Host "  Updated Cargo.lock (package gitui version = `"$Version`")" -ForegroundColor DarkGray

Write-Host "Version stamping completed successfully." -ForegroundColor Green
