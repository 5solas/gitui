#Requires -Version 7.0

<#
.SYNOPSIS
    Builds and packages a gitui fork release (zip, msi) and stamps the fork version.
.DESCRIPTION
    1. Validates working tree state (requires clean tracked tree).
    2. Reads upstream version from Cargo.toml and fork number from eng/hj/VERSION.
    3. Computes fork version string (e.g. 0.28.1-hj-1) and numeric version (e.g. 0.28.1.1).
    4. Stamps Cargo.toml and Cargo.lock with the fork version via eng/hj/Set-HjVersion.ps1.
    5. Builds release binary using `GITUI_RELEASE=1 cargo build --release --locked`.
    6. Verifies that `gitui.exe --version` reports the fork version string.
    7. Packages portable zip: target/hj/gitui-hj-win-x64-<ver>.zip (gitui.exe + LICENSE.md).
    8. Packages WiX MSI installer: target/hj/gitui-hj-win-x64-<ver>.msi via cargo wix.
    9. Restores Cargo.toml and Cargo.lock byte-identically in a `finally` block.
   10. Computes and prints SHA-256 checksums of generated assets.
   11. Optionally creates an annotated git tag (hj/v<ver>).
.PARAMETER HjNumber
    The fork release iteration number. Defaults to reading eng/hj/VERSION.
.PARAMETER SkipMsi
    Skips WiX MSI installer generation.
.PARAMETER SkipTag
    Skips creating the git release tag.
.PARAMETER SkipBuild
    Skips cargo build (useful for testing packaging or tagging).
.PARAMETER AllowDirty
    Allows running even if uncommitted changes exist in tracked files.
#>

[CmdletBinding()]
param (
    [int]$HjNumber = 0,
    [switch]$SkipMsi,
    [switch]$SkipTag,
    [switch]$SkipBuild,
    [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve tool paths
$gitCmd = Get-Command git -ErrorAction Stop
$gitExe = $gitCmd.Source

$cargoCmd = Get-Command cargo -ErrorAction Stop
$cargoExe = $cargoCmd.Source

# Ensure perl is available for build scripts if strawberry perl exists
$knownPerlDirs = @(
    (Join-Path $env:USERPROFILE "scoop\apps\perl\current\perl\bin"),
    (Join-Path $env:USERPROFILE "scoop\apps\perl\current\perl\site\bin")
)
foreach ($dir in $knownPerlDirs) {
    if ((Test-Path $dir) -and ($env:PATH -split ';' -notcontains $dir)) {
        $env:PATH = "$dir;" + $env:PATH
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
Set-Location $repoRoot

# 1. Check working tree status
$statusOutput = @(& $gitExe -C $repoRoot status --porcelain 2>$null | Where-Object { $_.Trim() })
$trackedModifications = @($statusOutput | Where-Object { -not $_.StartsWith('??') })

if ($trackedModifications.Count -gt 0 -and (-not $AllowDirty)) {
    throw "Working tree has uncommitted modifications to tracked files. Stash or commit changes, or pass -AllowDirty.`n$($trackedModifications -join "`n")"
}

$currentBranch = (& $gitExe -C $repoRoot branch --show-current 2>$null)
if ($currentBranch) {
    $currentBranch = $currentBranch.Trim()
}
if ($currentBranch -and $currentBranch -ne 'hj/main') {
    Write-Warning "Current branch is '$currentBranch'. Official releases should be built on 'hj/main'."
}

# 2. Read upstream version from Cargo.toml
$cargoTomlPath = Join-Path $repoRoot "Cargo.toml"
$cargoLockPath = Join-Path $repoRoot "Cargo.lock"

if (-not (Test-Path $cargoTomlPath)) {
    throw "Cargo.toml not found at '$cargoTomlPath'"
}
if (-not (Test-Path $cargoLockPath)) {
    throw "Cargo.lock not found at '$cargoLockPath'"
}

$tomlContent = [System.IO.File]::ReadAllText($cargoTomlPath, [System.Text.Encoding]::UTF8)
if ($tomlContent -match '(?m)^\s*version\s*=\s*"([^"]+)"') {
    $upstreamVersion = $Matches[1].Trim()
} else {
    throw "Could not find [package] version in '$cargoTomlPath'"
}

# 3. Resolve HjNumber
if ($HjNumber -le 0) {
    $versionFile = Join-Path $PSScriptRoot "VERSION"
    if (-not (Test-Path $versionFile)) {
        throw "VERSION file not found at '$versionFile'"
    }
    $rawHj = (Get-Content -Path $versionFile -Raw).Trim()
    if (-not [int]::TryParse($rawHj, [ref]$HjNumber)) {
        throw "Invalid integer in VERSION file: '$rawHj'"
    }
}

# 4. Compute version strings
$stringVersion = "$upstreamVersion-hj-$HjNumber"
$numericVersion = "$upstreamVersion.$HjNumber"
$tagName = "hj/v$stringVersion"

# MSI ProductVersion: Windows Installer ignores a 4th field and cargo-wix only accepts X.Y.Z,
# so fold the hj number into the patch field: 0.28.1 + hj-3 -> 0.28.103.
# Keeps hj-N upgrades ordered and stays above the upstream MSI (0.28.1) and below the next one (0.28.2 -> 0.28.201).
if ($HjNumber -ge 100) {
    throw "HjNumber must be below 100 to fit the MSI version scheme."
}
$upstreamParts = $upstreamVersion.Split('.')
$msiVersion = "$($upstreamParts[0]).$($upstreamParts[1]).$([int]$upstreamParts[2] * 100 + $HjNumber)"

Write-Host "=== gitui Fork Release Build ===" -ForegroundColor Cyan
Write-Host "Upstream Version: $upstreamVersion"
Write-Host "HJ Number:        $HjNumber"
Write-Host "String Version:   $stringVersion"
Write-Host "Numeric Version:  $numericVersion"
Write-Host "Tag Name:         $tagName"
Write-Host "SkipBuild:        $SkipBuild"
Write-Host "SkipMsi:          $SkipMsi"
Write-Host "SkipTag:          $SkipTag"
Write-Host "Repo Root:        $repoRoot`n"

# Output directory: target/hj (already ignored by .gitignore via /target)
$outputDir = Join-Path $repoRoot "target\hj"
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$zipPath = Join-Path $outputDir "gitui-hj-win-x64-$stringVersion.zip"
$msiPath = Join-Path $outputDir "gitui-hj-win-x64-$stringVersion.msi"

$setVersionScript = Join-Path $PSScriptRoot "Set-HjVersion.ps1"
if (-not (Test-Path $setVersionScript)) {
    throw "Set-HjVersion.ps1 script not found at '$setVersionScript'"
}

# 5. Stamp version, build, package, and restore
try {
    # (a) Stamp version into Cargo.toml and Cargo.lock
    & pwsh -NoProfile -File $setVersionScript -Version $stringVersion

    # (b) Build release binary with locked dependencies
    if (-not $SkipBuild) {
        Write-Host "`nBuilding gitui release binary (GITUI_RELEASE=1, --locked)..." -ForegroundColor Yellow
        $prevReleaseEnv = $env:GITUI_RELEASE
        $env:GITUI_RELEASE = "1"
        try {
            & $cargoExe build --release --locked
            if ($LASTEXITCODE -ne 0) {
                throw "cargo build --release --locked failed with exit code $LASTEXITCODE"
            }
        } finally {
            if ($null -ne $prevReleaseEnv) {
                $env:GITUI_RELEASE = $prevReleaseEnv
            } else {
                Remove-Item env:GITUI_RELEASE -ErrorAction SilentlyContinue
            }
        }

        $builtExe = Join-Path $repoRoot "target\release\gitui.exe"
        if (-not (Test-Path $builtExe)) {
            throw "Expected binary was not found at '$builtExe'"
        }

        # Verify built binary reports fork version
        Write-Host "`nVerifying gitui.exe version..." -ForegroundColor Yellow
        $versionReport = (& $builtExe --version 2>&1).Trim()
        Write-Host "gitui.exe output: $versionReport" -ForegroundColor White
        if ($versionReport -notmatch [regex]::Escape($stringVersion)) {
            throw "Binary version check failed: expected '$stringVersion', got '$versionReport'"
        }
        Write-Host "Version verification successful." -ForegroundColor Green
    }

    # (c) Package portable zip (gitui.exe + LICENSE.md at zip root)
    $builtExe = Join-Path $repoRoot "target\release\gitui.exe"
    if (Test-Path $builtExe) {
        Write-Host "`nPackaging portable zip archive..." -ForegroundColor Yellow
        $tempStaging = Join-Path ([System.IO.Path]::GetTempPath()) ("gitui-pkg-" + [Guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Path $tempStaging -Force | Out-Null
            Copy-Item -Path $builtExe -Destination (Join-Path $tempStaging "gitui.exe") -Force

            $licenseFile = Join-Path $repoRoot "LICENSE.md"
            if (Test-Path $licenseFile) {
                Copy-Item -Path $licenseFile -Destination (Join-Path $tempStaging "LICENSE.md") -Force
            }

            if (Test-Path $zipPath) {
                Remove-Item -Path $zipPath -Force
            }

            [System.IO.Compression.ZipFile]::CreateFromDirectory($tempStaging, $zipPath)
            Write-Host "Portable archive created: $zipPath" -ForegroundColor Green
        } finally {
            Remove-Item -Path $tempStaging -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warning "Binary '$builtExe' not found. Skipping zip packaging."
    }

    # (d) Package WiX MSI installer
    # Note on cargo-wix flag:
    # cargo-wix 0.3.3 enforces SemVer 2.0 (semver::Version::parse) on --install-version, which requires exactly 3 numeric parts (X.Y.Z).
    # Passing 4 parts (e.g. 0.28.1.1) fails with Error[7] (Version): expected end of input.
    # Meanwhile, WiX (candle.exe) requires purely numeric Product Version, so passing a SemVer pre-release with hyphens fails candle.
    # We pass --install-version $msiVersion (e.g. 0.28.101) to override the stamped pre-release version in Cargo.toml with a valid 3-part SemVer,
    # and output the file with the full fork version name (gitui-hj-win-x64-<ver>.msi).
    if (-not $SkipMsi) {
        if (-not (Test-Path $builtExe)) {
            Write-Warning "Binary '$builtExe' not found. Skipping MSI packaging."
        } else {
            $candleCmd = Get-Command candle -ErrorAction SilentlyContinue
            $lightCmd = Get-Command light -ErrorAction SilentlyContinue

            if (-not $candleCmd -or -not $lightCmd) {
                Write-Warning "WiX Toolset (candle.exe / light.exe) not detected on PATH. Skipping MSI packaging."
            } else {
                Write-Host "`nPackaging WiX MSI installer (install-version: $msiVersion)..." -ForegroundColor Yellow
                if (Test-Path $msiPath) {
                    Remove-Item -Path $msiPath -Force
                }

                & $cargoExe wix -p gitui --no-build --nocapture --install-version $msiVersion --output $msiPath
                if ($LASTEXITCODE -ne 0) {
                    throw "cargo wix failed with exit code $LASTEXITCODE"
                }

                if (Test-Path $msiPath) {
                    Write-Host "MSI installer created: $msiPath" -ForegroundColor Green
                } else {
                    throw "cargo wix finished but expected output '$msiPath' was not found."
                }
            }
        }
    } else {
        Write-Host "`nMSI generation skipped (-SkipMsi)." -ForegroundColor DarkGray
    }

} finally {
    # (e) Always restore Cargo.toml and Cargo.lock byte-identically
    Write-Host "`nRestoring Cargo.toml and Cargo.lock..." -ForegroundColor Yellow
    & pwsh -NoProfile -File $setVersionScript -Revert
}

# 6. Create annotated tag if requested
if (-not $SkipTag) {
    Write-Host "`nCreating annotated git tag '$tagName'..." -ForegroundColor Yellow
    $existingTag = (& $gitExe -C $repoRoot tag -l $tagName)
    if ($existingTag) {
        throw "Tag '$tagName' already exists."
    }

    $mergeBase = $null
    $hasUpstream = (& $gitExe -C $repoRoot rev-parse --verify upstream/master 2>$null)
    if ($hasUpstream) {
        $mbOutput = (& $gitExe -C $repoRoot merge-base HEAD upstream/master 2>$null)
        if ($LASTEXITCODE -eq 0 -and $mbOutput) {
            $mergeBase = $mbOutput.Trim()
        }
    }

    $tagMessage = "gitui $stringVersion"
    if ($mergeBase) {
        $tagMessage += "`n`nupstream-base: $mergeBase"
    }

    & $gitExe -C $repoRoot tag -a $tagName -m $tagMessage
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create annotated git tag '$tagName'"
    }
    Write-Host "Created tag: $tagName" -ForegroundColor Green
}

# 7. Output summary and SHA-256 checksums
Write-Host "`n===============================================================================" -ForegroundColor Cyan
Write-Host "                         RELEASE ARTIFACTS SUMMARY" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Version String:  $stringVersion"
Write-Host "Numeric Version: $numericVersion"
Write-Host "Tag:             $tagName"

$producedFiles = @($zipPath, $msiPath) | Where-Object { Test-Path $_ }
if ($producedFiles.Count -gt 0) {
    Write-Host "`nGenerated Artifacts & Checksums (SHA-256):" -ForegroundColor White
    foreach ($f in $producedFiles) {
        $hash = (Get-FileHash -Path $f -Algorithm SHA256).Hash.ToLowerInvariant()
        $sizeBytes = (Get-Item $f).Length
        $sizeFormatted = if ($sizeBytes -gt 1MB) { "{0:N2} MB" -f ($sizeBytes / 1MB) } else { "{0:N0} KB" -f ($sizeBytes / 1KB) }
        Write-Host "  - File:   $f" -ForegroundColor Green
        Write-Host "    Size:   $sizeBytes bytes ($sizeFormatted)"
        Write-Host "    SHA256: $hash"
    }
} else {
    Write-Host "`nNo artifacts were generated." -ForegroundColor DarkGray
}
Write-Host "===============================================================================`n" -ForegroundColor Cyan
