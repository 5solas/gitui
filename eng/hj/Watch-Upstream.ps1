<#
.SYNOPSIS
    Monitors upstream changes, evaluates patch-stack rebase/merge feasibility, and reports via GitHub issues.
.DESCRIPTION
    1. Validates git workspace and tool prerequisites.
    2. Self-copies and re-executes from a temporary location so branch checkouts do not modify or lock the script.
    3. Fetches remotes (upstream, origin) unless -SkipFetch is specified.
    4. Compares upstream/master with origin/master (or simulated -BaseRef).
       - If up-to-date: logs status, closes any open watcher issue, and exits 0.
    5. Analyzes new upstream commits and detects file overlaps between upstream and topic branches (early-warning signal).
    6. Performs dry-run patch-stack rebase for each topic onto upstream/master using temporary branches (tmp/watch-*).
       Tracks clean rebases, upstream-adopted commits (git cherry), and conflicts (with conflicting file list).
    7. Performs dry-run integration merge into a temporary hj/main branch.
    8. If clean, optionally runs cargo build --locked and cargo test --workspace --locked.
    9. Generates a comprehensive Korean markdown report.
   10. Reports through a single GitHub issue with label 'upstream-sync' (creates or updates issue + comment).
   11. Idempotent: restores workspace to original branch and deletes temporary branches in all exit paths.
.PARAMETER BaseRef
    Simulated base commit SHA or ref for origin/master (e.g. for testing older states).
.PARAMETER UpstreamRef
    Target upstream ref (default: upstream/master).
.PARAMETER OriginRef
    Base origin ref (default: origin/master).
.PARAMETER Topics
    Path to topics list file or git ref (default: hj/infra:eng/hj/topics.txt with fallback to eng/hj/topics.txt).
.PARAMETER SkipBuild
    Skips cargo build step.
.PARAMETER SkipTests
    Skips cargo test step.
.PARAMETER SkipFetch
    Skips git fetch operations.
.PARAMETER NoIssue
    Skips all GitHub Issue operations (create, edit, comment, close). Useful for local testing.
.PARAMETER ReportPath
    Path to save the generated markdown report.
.PARAMETER SummaryJson
    Path to save a structured JSON summary of the watch results.
#>

[CmdletBinding()]
param(
    [string]$BaseRef,
    [string]$UpstreamRef = "upstream/master",
    [string]$OriginRef = "origin/master",
    [string]$Topics,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$SkipFetch,
    [switch]$NoIssue,
    [string]$ReportPath,
    [string]$SummaryJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Re-exec from a temporary directory copy so that branch checkouts and rebases
# do not overwrite, delete, or lock the executing script file itself.
# -----------------------------------------------------------------------------
if (-not $env:HJ_WATCH_REEXEC) {
    $scriptFile = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($scriptFile -and (Test-Path -Path $scriptFile -PathType Leaf)) {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hj-watch-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $tempScript = Join-Path $tempDir ([System.IO.Path]::GetFileName($scriptFile))
        Copy-Item -Path $scriptFile -Destination $tempScript -Force

        $forwardArgs = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [System.Management.Automation.SwitchParameter]) {
                if ($val.IsPresent) {
                    $forwardArgs.Add("-$key")
                }
            } else {
                $forwardArgs.Add("-$key")
                $forwardArgs.Add("$val")
            }
        }

        $env:HJ_WATCH_REEXEC = "1"
        try {
            & pwsh -NoProfile -File $tempScript @forwardArgs
            $exitCode = $LASTEXITCODE
            exit $exitCode
        } finally {
            Remove-Item env:HJ_WATCH_REEXEC -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Resolve tool paths
$gitCmd = Get-Command git -ErrorAction Stop
$gitExe = $gitCmd.Source

$cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
$cargoExe = if ($cargoCmd) { $cargoCmd.Source } else { $null }

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

# Resolve repository root
$repoRoot = (& $gitExe rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    Write-Error "Not inside a git repository."
    exit 1
}
$repoRoot = $repoRoot.Trim()
Set-Location $repoRoot

# Ensure git config has minimal user information and conflict resolution settings
$configuredUserName = (& $gitExe config user.name 2>$null)
if (-not $configuredUserName) {
    & $gitExe config user.name "github-actions[bot]"
}
$configuredUserEmail = (& $gitExe config user.email 2>$null)
if (-not $configuredUserEmail) {
    & $gitExe config user.email "github-actions[bot]@users.noreply.github.com"
}
& $gitExe config rerere.enabled true
& $gitExe config merge.conflictstyle zdiff3

function Test-ConflictMarkersPresent([string]$FilePath) {
    if (-not (Test-Path $FilePath)) {
        return $false
    }
    $match = Select-String -Path $FilePath -Pattern '^<{7}(\s|$)' -Quiet -ErrorAction SilentlyContinue
    return [bool]$match
}

function Get-TargetGitHubRepo {
    if ($env:GH_REPO) {
        return $env:GH_REPO
    }
    if ($env:GITHUB_REPOSITORY) {
        return $env:GITHUB_REPOSITORY
    }
    $originUrl = (& $gitExe remote get-url origin 2>$null)
    if ($originUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+?)(\.git)?$') {
        return "$($Matches['owner'])/$($Matches['repo'])"
    }
    return "5solas/gitui"
}

# Validate working tree state
$statusOutput = @(& $gitExe status --porcelain 2>$null | Where-Object { $_.Trim() })
$trackedModifications = @($statusOutput | Where-Object { -not $_.StartsWith('??') })
if ($trackedModifications.Count -gt 0) {
    Write-Error "Working tree has uncommitted tracked modifications:`n$($trackedModifications -join "`n")"
    exit 1
}

# Record current branch for safe restoration
$originalBranch = (& $gitExe branch --show-current 2>$null)
if ($originalBranch) {
    $originalBranch = $originalBranch.Trim()
}
if (-not $originalBranch) {
    $originalBranch = (& $gitExe rev-parse HEAD 2>$null).Trim()
}

$createdTempBranches = [System.Collections.Generic.List[string]]::new()
$sessionTimestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$tempTopicsFile = $null

try {
    # -------------------------------------------------------------------------
    # Step 1: Ensure remotes and fetch
    # -------------------------------------------------------------------------
    if (-not $SkipFetch) {
        Write-Host "==> [1/6] Checking and fetching remotes..." -ForegroundColor Cyan

        $existingRemotes = @(& $gitExe remote 2>$null)
        if ($existingRemotes -notcontains 'upstream') {
            Write-Host "    Adding upstream remote (https://github.com/gitui-org/gitui.git)..." -ForegroundColor White
            & $gitExe remote add upstream https://github.com/gitui-org/gitui.git
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to add upstream remote."
                exit 1
            }
        }

        Write-Host "    Fetching upstream..." -ForegroundColor White
        & $gitExe fetch upstream --prune --tags
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to fetch upstream remote."
            exit 1
        }

        Write-Host "    Fetching origin..." -ForegroundColor White
        & $gitExe fetch origin --prune
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to fetch origin remote."
            exit 1
        }
    } else {
        Write-Host "==> [1/6] Skipping remote fetch (-SkipFetch)." -ForegroundColor DarkGray
    }

    # -------------------------------------------------------------------------
    # Step 2: Resolve refs and compare upstream with origin
    # -------------------------------------------------------------------------
    Write-Host "==> [2/6] Comparing upstream against base..." -ForegroundColor Cyan

    $upstreamShaRaw = (& $gitExe rev-parse --verify $UpstreamRef 2>$null)
    if (-not $upstreamShaRaw) {
        Write-Error "Failed to resolve UpstreamRef '$UpstreamRef'."
        exit 1
    }
    $targetUpstreamSha = $upstreamShaRaw.Trim()

    $effectiveBaseRef = if ($BaseRef) { $BaseRef } else { $OriginRef }
    $baseShaRaw = (& $gitExe rev-parse --verify $effectiveBaseRef 2>$null)
    if (-not $baseShaRaw) {
        Write-Error "Failed to resolve base ref '$effectiveBaseRef'."
        exit 1
    }
    $baseSha = $baseShaRaw.Trim()

    $targetUpstreamShortSha = $targetUpstreamSha.Substring(0, [System.Math]::Min(8, $targetUpstreamSha.Length))
    $baseShortSha = $baseSha.Substring(0, [System.Math]::Min(8, $baseSha.Length))

    Write-Host "    Upstream target : $targetUpstreamSha ($targetUpstreamShortSha)"
    Write-Host "    Base reference  : $baseSha ($baseShortSha) [from $effectiveBaseRef]"

    $isUpToDate = ($targetUpstreamSha -eq $baseSha)
    if ($isUpToDate) {
        Write-Host "==> Upstream is already up to date ($baseShortSha). [동기화 최신 상태]" -ForegroundColor Green

        if (-not $NoIssue) {
            $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
            if ($ghCmd) {
                $targetRepo = Get-TargetGitHubRepo
                Write-Host "    Checking for open 'upstream-sync' issues in $targetRepo to close..." -ForegroundColor White
                $openIssuesLines = @(& $ghCmd.Source issue list --repo $targetRepo --label "upstream-sync" --state open --json number,title 2>$null)
                if ($LASTEXITCODE -eq 0 -and $openIssuesLines.Count -gt 0) {
                    $openIssues = ($openIssuesLines -join "`n") | ConvertFrom-Json
                    foreach ($issue in $openIssues) {
                        Write-Host "    Closing issue #$($issue.number) ('$($issue.title)')..." -ForegroundColor Yellow
                        & $ghCmd.Source issue close $issue.number --repo $targetRepo --comment "업스트림 최신 커밋($targetUpstreamShortSha)과 origin/master가 일치하여 동기화 이슈를 자동으로 종료합니다." 2>$null
                    }
                }
            }
        }

        # Save summary json if requested
        if ($SummaryJson) {
            $jsonObj = [PSCustomObject]@{
                Status              = "UpToDate"
                TargetUpstreamSha   = $targetUpstreamSha
                BaseSha             = $baseSha
                NewCommitCount      = 0
                TopicsClean         = $true
                MainMergeClean      = $true
                BuildStatus         = "Skipped"
                TestStatus          = "Skipped"
            }
            $jsonDir = [System.IO.Path]::GetDirectoryName($SummaryJson)
            if ($jsonDir -and -not (Test-Path $jsonDir)) {
                New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
            }
            $jsonObj | ConvertTo-Json -Depth 5 | Set-Content -Path $SummaryJson -Encoding utf8
        }

        Write-Host "==> Watcher completed successfully. (Up to date)" -ForegroundColor Green
        exit 0
    }

    # -------------------------------------------------------------------------
    # Step 3: Analyze new upstream commits and file changes
    # -------------------------------------------------------------------------
    Write-Host "==> [3/6] Analyzing new upstream commits..." -ForegroundColor Cyan

    $commitCountStr = (& $gitExe rev-list --count "$baseSha..$targetUpstreamSha" 2>$null).Trim()
    $upstreamCommitCount = [int]$commitCountStr
    Write-Host "    New upstream commits: $upstreamCommitCount" -ForegroundColor Yellow

    $rawLogLines = @(& $gitExe log --oneline "$baseSha..$targetUpstreamSha" 2>$null)
    $displayedLogLines = [System.Collections.Generic.List[string]]::new()
    $maxLogLines = 30
    for ($i = 0; $i -lt $rawLogLines.Count; $i++) {
        if ($i -lt $maxLogLines) {
            $displayedLogLines.Add($rawLogLines[$i])
        } else {
            $displayedLogLines.Add("... and $($rawLogLines.Count - $maxLogLines) more commits")
            break
        }
    }

    $upstreamChangedFiles = @(& $gitExe diff --name-only "$baseSha..$targetUpstreamSha" 2>$null | Where-Object { $_.Trim() })
    Write-Host "    Upstream modified files count: $($upstreamChangedFiles.Count)" -ForegroundColor White

    # Resolve topic branches
    $resolvedTopicsPath = $null
    $tempTopicsFile = $null
    if ($PSBoundParameters.ContainsKey('Topics') -and -not [string]::IsNullOrWhiteSpace($Topics)) {
        $resolvedTopicsPath = if ([System.IO.Path]::IsPathRooted($Topics)) { $Topics } else { Join-Path $repoRoot $Topics }
    } else {
        $infraTopics = & $gitExe show "hj/infra:eng/hj/topics.txt" 2>$null
        if ($LASTEXITCODE -eq 0 -and $infraTopics) {
            $tempTopicsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("hj-watch-topics-" + [Guid]::NewGuid().ToString("N") + ".txt")
            Set-Content -Path $tempTopicsFile -Value $infraTopics -Encoding utf8
            $resolvedTopicsPath = $tempTopicsFile
        } else {
            $resolvedTopicsPath = Join-Path $repoRoot "eng/hj/topics.txt"
        }
    }

    if (-not (Test-Path $resolvedTopicsPath)) {
        Write-Error "Topics file not found at: $resolvedTopicsPath"
        exit 1
    }

    $topicLines = @(Get-Content -Path $resolvedTopicsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($topicLines.Count -eq 0) {
        Write-Error "No topic branches defined in $resolvedTopicsPath."
        exit 1
    }
    Write-Host "    Topics to check: $($topicLines -join ', ')" -ForegroundColor White

    # Ensure local topic branches exist (fetch from origin if needed)
    foreach ($topic in $topicLines) {
        $hasLocalBranch = (& $gitExe rev-parse --verify "refs/heads/$topic" 2>$null)
        if (-not $hasLocalBranch) {
            $hasRemoteBranch = (& $gitExe rev-parse --verify "refs/remotes/origin/$topic" 2>$null)
            if ($hasRemoteBranch) {
                Write-Host "    Creating local branch '$topic' from 'origin/$topic'..." -ForegroundColor DarkGray
                & $gitExe branch --track $topic "origin/$topic" 2>$null
            } else {
                Write-Error "Topic branch '$topic' not found locally or in origin."
                exit 1
            }
        }
    }

    # -------------------------------------------------------------------------
    # Step 4: Early-Warning Overlap Detection
    # -------------------------------------------------------------------------
    Write-Host "==> [4/6] Checking for file overlaps (early-warning signal)..." -ForegroundColor Cyan
    $topicOverlaps = [System.Collections.Generic.Dictionary[string, string[]]]::new()
    $hasAnyOverlaps = $false

    foreach ($topic in $topicLines) {
        $topicBase = (& $gitExe merge-base $targetUpstreamSha $topic 2>$null)
        if (-not $topicBase) {
            $topicBase = (& $gitExe merge-base $baseSha $topic 2>$null)
        }
        $diffRef = if ($topicBase) { $topicBase.Trim() } else { $baseSha }
        $topicFiles = @(& $gitExe diff --name-only "$diffRef..$topic" 2>$null | Where-Object { $_.Trim() })
        
        $overlapping = @($topicFiles | Where-Object { $upstreamChangedFiles -contains $_ })
        $topicOverlaps[$topic] = $overlapping
        if ($overlapping.Count -gt 0) {
            $hasAnyOverlaps = $true
            Write-Host "    [Overlap] Topic '$topic' touches $($overlapping.Count) file(s) also modified in upstream:" -ForegroundColor Yellow
            foreach ($f in $overlapping) {
                Write-Host "      - $f" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    Topic '$topic': No file overlaps with upstream changes." -ForegroundColor DarkGray
        }
    }

    # -------------------------------------------------------------------------
    # Step 5: Dry-Run Rebase of Topic Branches
    # -------------------------------------------------------------------------
    Write-Host "==> [5/6] Testing patch-stack rebase on temporary branches..." -ForegroundColor Cyan
    $topicResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $hasRebaseConflict = $false

    foreach ($topic in $topicLines) {
        Write-Host "--- Testing rebase for topic: $topic" -ForegroundColor White
        $beforeSha = (& $gitExe rev-parse $topic 2>$null).Trim()
        $beforeCount = [int](& $gitExe rev-list --count "$baseSha..$topic" 2>$null).Trim()

        # Identify upstream-adopted commits via cherry
        $cherryLines = @(& $gitExe cherry $targetUpstreamSha $topic 2>$null)
        $skippedCommits = [System.Collections.Generic.List[string]]::new()
        foreach ($cLine in $cherryLines) {
            if ($cLine -match '^-\s+([0-9a-fA-F]+)') {
                $cSha = $Matches[1]
                $cSummary = (& $gitExe log -1 --format="%h %s" $cSha 2>$null).Trim()
                $skippedCommits.Add($cSummary)
            }
        }

        # Create temporary branch for test rebase
        $safeName = $topic -replace '[^a-zA-Z0-9_\-]', '-'
        $tempTopicBranch = "tmp/watch-$safeName-$sessionTimestamp"
        & $gitExe branch -f $tempTopicBranch $topic
        $createdTempBranches.Add($tempTopicBranch)

        & $gitExe checkout $tempTopicBranch 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to checkout temporary test branch '$tempTopicBranch'."
            exit 1
        }

        # Attempt rebase
        & $gitExe rebase $targetUpstreamSha $tempTopicBranch 2>&1 | Out-Null
        $rebaseCode = $LASTEXITCODE

        if ($rebaseCode -ne 0) {
            $gitDir = (& $gitExe rev-parse --git-dir 2>$null)
            if ($gitDir) {
                $gitDir = $gitDir.Trim()
                $inRebase = (Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))
                if ($inRebase) {
                    $unmerged = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
                    $hasMarkers = $false
                    foreach ($f in $unmerged) {
                        if (Test-ConflictMarkersPresent $f) {
                            $hasMarkers = $true
                            break
                        }
                    }
                    $rererePending = @(& $gitExe rerere status 2>$null | Where-Object { $_.Trim() })
                    if (-not $hasMarkers -and $rererePending.Count -eq 0 -and $unmerged.Count -gt 0) {
                        Write-Host "    [rerere] Auto-resolved conflicts for '$topic'. Continuing rebase..." -ForegroundColor Yellow
                        & $gitExe add -A
                        $env:GIT_EDITOR = 'true'
                        & $gitExe rebase --continue 2>&1 | Out-Null
                        $rebaseCode = $LASTEXITCODE
                    }
                }
            }
        }

        $conflictFiles = @()
        $afterSha = $null
        $afterCount = 0
        $status = "Clean"

        if ($rebaseCode -ne 0) {
            $hasRebaseConflict = $true
            $conflictFiles = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
            & $gitExe rebase --abort 2>$null
            $status = "Conflict"
            Write-Host "    [CONFLICT] Rebase failed for '$topic'. Conflicting files: $($conflictFiles -join ', ')" -ForegroundColor Red
        } else {
            $afterSha = (& $gitExe rev-parse $tempTopicBranch 2>$null).Trim()
            $afterCount = [int](& $gitExe rev-list --count "$targetUpstreamSha..$tempTopicBranch" 2>$null).Trim()
            if ($afterCount -eq 0 -or $afterSha -eq $targetUpstreamSha) {
                $status = "Adopted (Empty)"
                Write-Host "    [Adopted] All commits adopted upstream for '$topic'." -ForegroundColor Yellow
            } else {
                Write-Host "    [Clean] Rebase succeeded for '$topic' ($afterCount commit(s))." -ForegroundColor Green
            }
        }

        $topicResults.Add([PSCustomObject]@{
            Topic              = $topic
            TempBranch         = $tempTopicBranch
            BeforeSha          = $beforeSha
            AfterSha           = $afterSha
            BeforeCommitCount  = $beforeCount
            AfterCommitCount   = $afterCount
            SkippedCommits     = $skippedCommits.ToArray()
            Overlaps           = $topicOverlaps[$topic]
            ConflictFiles      = $conflictFiles
            Status             = $status
        })
    }

    # -------------------------------------------------------------------------
    # Step 6: Dry-Run hj/main Integration Merge & Optional Build
    # -------------------------------------------------------------------------
    Write-Host "==> [6/6] Testing hj/main integration merge..." -ForegroundColor Cyan
    $mainMergeStatus = "Skipped"
    $mainMergeConflicts = @()
    $mainMergeSha = $null

    if ($hasRebaseConflict) {
        $mainMergeStatus = "Skipped (Topic rebase conflict)"
        Write-Host "    Skipping hj/main merge due to topic rebase conflicts." -ForegroundColor Yellow
    } else {
        $tempMainBranch = "tmp/watch-hj-main-$sessionTimestamp"
        $createdTempBranches.Add($tempMainBranch)
        & $gitExe checkout -B $tempMainBranch $targetUpstreamSha 2>$null

        $mainConflictFound = $false
        foreach ($tr in $topicResults) {
            if ($tr.Status -eq "Adopted (Empty)") {
                continue
            }
            Write-Host "    Merging '$($tr.Topic)' into $tempMainBranch..." -ForegroundColor White
            & $gitExe merge --no-ff --no-edit $tr.TempBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $unmerged = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
                $hasMarkers = $false
                foreach ($f in $unmerged) {
                    if (Test-ConflictMarkersPresent $f) {
                        $hasMarkers = $true
                        break
                    }
                }
                $rererePending = @(& $gitExe rerere status 2>$null | Where-Object { $_.Trim() })
                if (-not $hasMarkers -and $rererePending.Count -eq 0 -and $unmerged.Count -gt 0) {
                    Write-Host "    [rerere] Auto-resolved merge conflicts for '$($tr.Topic)'. Committing..." -ForegroundColor Yellow
                    & $gitExe add -A
                    & $gitExe commit --no-edit 2>&1 | Out-Null
                }
            }

            if ($LASTEXITCODE -ne 0) {
                $mainConflictFound = $true
                $mainMergeConflicts = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
                & $gitExe merge --abort 2>$null
                $mainMergeStatus = "Conflict on $($tr.Topic)"
                Write-Host "    [CONFLICT] Merge failed for '$($tr.Topic)' into hj/main. Conflicting files: $($mainMergeConflicts -join ', ')" -ForegroundColor Red
                break
            }
        }

        if (-not $mainConflictFound) {
            $mainMergeStatus = "Clean"
            $mainMergeSha = (& $gitExe rev-parse $tempMainBranch 2>$null).Trim()
            Write-Host "    [Clean] hj/main integration merge succeeded ($($mainMergeSha.Substring(0, 8)))." -ForegroundColor Green
        }
    }

    # Optional Build Check on merged tree
    $buildStatus = "Skipped"
    $testStatus = "Skipped"
    if ($mainMergeStatus -eq "Clean" -and -not $SkipBuild -and $cargoExe) {
        Write-Host "==> Running verification build (cargo build --locked)..." -ForegroundColor Cyan
        & $cargoExe build --locked
        if ($LASTEXITCODE -eq 0) {
            $buildStatus = "Passed"
            Write-Host "    Build succeeded." -ForegroundColor Green

            if (-not $SkipTests) {
                Write-Host "==> Running workspace tests (cargo test --workspace --locked)..." -ForegroundColor Cyan
                & $cargoExe test --workspace --locked
                if ($LASTEXITCODE -eq 0) {
                    $testStatus = "Passed"
                    Write-Host "    Workspace tests passed." -ForegroundColor Green
                } else {
                    $testStatus = "Failed"
                    Write-Host "    Workspace tests failed (exit code $LASTEXITCODE)." -ForegroundColor Red
                }
            } else {
                $testStatus = "Skipped (-SkipTests)"
            }
        } else {
            $buildStatus = "Failed"
            Write-Host "    cargo build failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            $testStatus = "Skipped"
        }
    } elseif ($SkipBuild) {
        $buildStatus = "Skipped (-SkipBuild)"
        $testStatus = "Skipped (-SkipBuild)"
    }

    # -------------------------------------------------------------------------
    # Generate Korean Markdown Report
    # -------------------------------------------------------------------------
    $tick = [char]0x60
    $tripleTick = "$tick$tick$tick"
    $issueTitle = "upstream: $upstreamCommitCount new commits ($targetUpstreamShortSha)"
    $reportLines = [System.Collections.Generic.List[string]]::new()

    $reportLines.Add("## 업스트림 변경 사항 감지 및 패치 스택 점검 결과")
    $reportLines.Add("")
    $reportLines.Add("공식 업스트림(${tick}gitui-org/gitui${tick})의 ${tick}master${tick} 브랜치에 새로운 커밋이 감지되었습니다.")
    $reportLines.Add("")
    $reportLines.Add("### 1. 요약 (Summary)")
    $reportLines.Add("")
    $reportLines.Add("| 항목 | 상태 및 상세 정보 |")
    $reportLines.Add("| :--- | :--- |")
    $reportLines.Add("| **기준 커밋 (${tick}origin/master${tick})** | $baseShortSha ($baseSha) |")
    $reportLines.Add("| **업스트림 최신 커밋 (${tick}upstream/master${tick})** | $targetUpstreamShortSha ($targetUpstreamSha) |")
    $reportLines.Add("| **신규 업스트림 커밋 수** | **$upstreamCommitCount** 건 |")

    $overallPatchStatus = if ($hasRebaseConflict -or $mainMergeStatus -like "Conflict*") {
        ":warning: **충돌 발생 (Conflict)**"
    } elseif ($hasAnyOverlaps) {
        ":warning: **정상 리베이스 완료 (주의: 파일 중복 경고)**"
    } else {
        ":white_check_mark: **정상 적용 가능 (Clean)**"
    }
    $reportLines.Add("| **패치 스택 적용 상태** | $overallPatchStatus |")
    $reportLines.Add("| **통합 브랜치 (${tick}hj/main${tick}) 머지** | $(if ($mainMergeStatus -eq 'Clean') { ':white_check_mark: Clean' } elseif ($mainMergeStatus -like 'Conflict*') { ':x: ' + $mainMergeStatus } else { ':fast_forward: ' + $mainMergeStatus }) |")
    $reportLines.Add("| **빌드 검증 (${tick}cargo build --locked${tick})** | $(if ($buildStatus -eq 'Passed') { ':white_check_mark: Passed' } elseif ($buildStatus -eq 'Failed') { ':x: Failed' } else { ':fast_forward: ' + $buildStatus }) |")
    $reportLines.Add("| **테스트 검증 (${tick}cargo test --workspace${tick})** | $(if ($testStatus -eq 'Passed') { ':white_check_mark: Passed' } elseif ($testStatus -eq 'Failed') { ':x: Failed' } else { ':fast_forward: ' + $testStatus }) |")
    $reportLines.Add("")

    # Topic table
    $reportLines.Add("### 2. 토픽 브랜치 점검 내역")
    $reportLines.Add("")
    $reportLines.Add("| 토픽 브랜치 | 리베이스 상태 | 건너뛴 커밋 | 파일 중복 경고 (Overlaps) | 충돌 파일 목록 |")
    $reportLines.Add("| :--- | :---: | :---: | :--- | :--- |")

    foreach ($tr in $topicResults) {
        $stEmoji = switch -Wildcard ($tr.Status) {
            "Clean" { ":white_check_mark: Clean" }
            "Adopted*" { ":large_orange_diamond: Adopted" }
            "Conflict*" { ":x: Conflict" }
            Default { $tr.Status }
        }
        $skipCount = $tr.SkippedCommits.Count
        $overlapStr = if ($tr.Overlaps.Count -gt 0) {
            ($tr.Overlaps | ForEach-Object { "${tick}$_${tick}" }) -join ", "
        } else {
            "없음"
        }
        $conflictStr = if ($tr.ConflictFiles.Count -gt 0) {
            ($tr.ConflictFiles | ForEach-Object { "${tick}$_${tick}" }) -join ", "
        } else {
            "없음"
        }
        $reportLines.Add("| ${tick}$($tr.Topic)${tick} | $stEmoji | $skipCount 건 | $overlapStr | $conflictStr |")
    }
    $reportLines.Add("")

    # Skipped commits detail if any
    $allSkippedCommits = @($topicResults | ForEach-Object { $_.SkippedCommits } | Where-Object { $_ })
    if ($allSkippedCommits.Count -gt 0) {
        $reportLines.Add("#### :information_source: 업스트림에 이미 반영된 커밋 (Skipped Commits)")
        $reportLines.Add("")
        foreach ($sc in $allSkippedCommits) {
            $reportLines.Add("- $sc")
        }
        $reportLines.Add("")
    }

    # Early-warning overlap detail
    if ($hasAnyOverlaps) {
        $reportLines.Add("> [!WARNING]")
        $reportLines.Add("> **파일 변경 중복 감지 (Early-Warning Overlaps)**:")
        $reportLines.Add("> 업스트림에서 수정된 파일 중 포크 토픽 브랜치에서 이미 수정된 파일이 포함되어 있습니다.")
        $reportLines.Add("> 현재 리베이스가 성공하더라도 향후 충돌 가능성이 높으므로 변경 내역을 확인하십시오.")
        $reportLines.Add("")
    }

    # Conflict detail
    if ($hasRebaseConflict -or $mainMergeStatus -like "Conflict*") {
        $reportLines.Add("> [!CAUTION]")
        $reportLines.Add("> **충돌 발생 (Conflict Detected)**:")
        $reportLines.Add("> 자동 리베이스 또는 머지 중 충돌이 발생했습니다. 로컬 작업 공간에서 수동으로 충돌을 해결해야 합니다.")
        $reportLines.Add("")
    }

    # Upstream commit log
    $reportLines.Add("### 3. 신규 업스트림 커밋 목록 ($upstreamCommitCount 건)")
    $reportLines.Add("")
    $reportLines.Add("<details>")
    $reportLines.Add("<summary>커밋 히스토리 펼치기 (최대 $maxLogLines 건)</summary>")
    $reportLines.Add("")
    $reportLines.Add("${tripleTick}text")
    foreach ($l in $displayedLogLines) {
        $reportLines.Add($l)
    }
    $reportLines.Add($tripleTick)
    $reportLines.Add("")
    $reportLines.Add("</details>")
    $reportLines.Add("")

    # Local application commands
    $reportLines.Add("### 4. 로컬 동기화 적용 가이드")
    $reportLines.Add("")
    if (-not $hasRebaseConflict -and $mainMergeStatus -eq "Clean") {
        $reportLines.Add("모든 패치가 충돌 없이 정상 적용 가능합니다. 로컬 터미널에서 아래 명령을 실행하여 동기화를 완료하십시오:")
        $reportLines.Add("")
        $reportLines.Add("${tripleTick}pwsh")
        $reportLines.Add("# 1. 사전 드라이런 검증")
        $reportLines.Add("pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1 -DryRun")
        $reportLines.Add("")
        $reportLines.Add("# 2. 로컬 동기화 및 빌드/테스트 수행")
        $reportLines.Add("pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1")
        $reportLines.Add("")
        $reportLines.Add("# 3. 원격(origin) 저장소로 푸시")
        $reportLines.Add("pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1 -Push")
        $reportLines.Add($tripleTick)
    } else {
        $reportLines.Add("충돌이 감지되었으므로 수동 리베이스를 진행해야 합니다:")
        $reportLines.Add("")
        $reportLines.Add("${tripleTick}pwsh")
        $reportLines.Add("# 1. 최신 리모트 정보 가져오기")
        $reportLines.Add("git fetch upstream; git fetch origin")
        $reportLines.Add("")
        $reportLines.Add("# 2. 충돌이 발생한 토픽 브랜치로 전환 후 업스트림 위로 리베이스")
        $conflictedTopics = @($topicResults | Where-Object { $_.Status -eq "Conflict" } | ForEach-Object { $_.Topic })
        $exampleTopic = if ($conflictedTopics.Count -gt 0) { $conflictedTopics[0] } else { "feature/worktree" }
        $reportLines.Add("git checkout $exampleTopic")
        $reportLines.Add("git rebase upstream/master")
        $reportLines.Add("")
        $reportLines.Add("# 3. 충돌 파일 수정 후 리베이스 완료")
        $reportLines.Add("git add <수정된파일>")
        $reportLines.Add("git rebase --continue")
        $reportLines.Add("")
        $reportLines.Add("# 4. 전체 동기화 재실행 및 푸시")
        $reportLines.Add("pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1 -Push")
        $reportLines.Add($tripleTick)
    }
    $reportLines.Add("")
    $reportLines.Add("---")
    $reportLines.Add("*이 알림은 GitHub Actions 워크플로(${tick}hj-upstream-watch.yml${tick})에 의해 자동 생성되었습니다.*")

    $reportMarkdown = $reportLines -join "`n"

    # Save to ReportPath if specified
    if ($ReportPath) {
        $reportDir = [System.IO.Path]::GetDirectoryName($ReportPath)
        if ($reportDir -and -not (Test-Path $reportDir)) {
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        }
        Set-Content -Path $ReportPath -Value $reportMarkdown -Encoding utf8
        Write-Host "    Saved markdown report to: $ReportPath" -ForegroundColor DarkGray
    }

    # Save summary json if requested
    if ($SummaryJson) {
        $jsonObj = [PSCustomObject]@{
            Status              = if ($hasRebaseConflict -or $mainMergeStatus -like "Conflict*") { "Conflict" } else { "Clean" }
            TargetUpstreamSha   = $targetUpstreamSha
            BaseSha             = $baseSha
            NewCommitCount      = $upstreamCommitCount
            TopicsClean         = (-not $hasRebaseConflict)
            MainMergeClean      = ($mainMergeStatus -eq "Clean")
            BuildStatus         = $buildStatus
            TestStatus          = $testStatus
            Overlaps            = $topicOverlaps
            TopicResults        = $topicResults
        }
        $jsonDir = [System.IO.Path]::GetDirectoryName($SummaryJson)
        if ($jsonDir -and -not (Test-Path $jsonDir)) {
            New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
        }
        $jsonObj | ConvertTo-Json -Depth 5 | Set-Content -Path $SummaryJson -Encoding utf8
        Write-Host "    Saved JSON summary to: $SummaryJson" -ForegroundColor DarkGray
    }

    # Output report to console
    Write-Host ""
    Write-Host "===============================================================================" -ForegroundColor Green
    Write-Host "                       UPSTREAM WATCH REPORT PREVIEW" -ForegroundColor Green
    Write-Host "===============================================================================" -ForegroundColor Green
    Write-Host $reportMarkdown
    Write-Host ""

    # -------------------------------------------------------------------------
    # Step 7: Report via GitHub Issue
    # -------------------------------------------------------------------------
    if (-not $NoIssue) {
        $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
        if ($ghCmd) {
            $targetRepo = Get-TargetGitHubRepo
            Write-Host "==> Publishing report via GitHub Issues ($targetRepo)..." -ForegroundColor Cyan

            # Ensure label exists
            $labelListLines = @(& $ghCmd.Source label list --repo $targetRepo --json name 2>$null)
            $labelExists = $false
            if ($LASTEXITCODE -eq 0 -and $labelListLines.Count -gt 0) {
                $labels = ($labelListLines -join "`n") | ConvertFrom-Json
                foreach ($lbl in $labels) {
                    if ($lbl.name -eq "upstream-sync") {
                        $labelExists = $true
                        break
                    }
                }
            }
            if (-not $labelExists) {
                Write-Host "    Creating label 'upstream-sync'..." -ForegroundColor White
                & $ghCmd.Source label create "upstream-sync" --repo $targetRepo --color "1d76db" --description "Upstream sync watcher notifications" 2>$null
            }

            # Check for existing open issue with label
            $openIssuesLines = @(& $ghCmd.Source issue list --repo $targetRepo --label "upstream-sync" --state open --json number,title,url 2>$null)
            $existingIssue = $null
            if ($LASTEXITCODE -eq 0 -and $openIssuesLines.Count -gt 0) {
                $openIssues = ($openIssuesLines -join "`n") | ConvertFrom-Json
                if ($openIssues.Count -gt 0) {
                    $existingIssue = $openIssues[0]
                }
            }

            if ($existingIssue -and $existingIssue.title -eq $issueTitle) {
                # Same upstream commit as the last report: nothing new to say, avoid a daily comment.
                Write-Host "    Issue #$($existingIssue.number) already reports $targetUpstreamShortSha; leaving it unchanged." -ForegroundColor DarkGray
            } elseif ($existingIssue) {
                $issueNum = $existingIssue.number
                Write-Host "    Updating existing open issue #$issueNum ('$($existingIssue.title)')..." -ForegroundColor Yellow
                & $ghCmd.Source issue edit $issueNum --repo $targetRepo --title $issueTitle --body $reportMarkdown
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Issue #$issueNum updated successfully." -ForegroundColor Green
                    & $ghCmd.Source issue comment $issueNum --repo $targetRepo --body "업스트림 최신 커밋($targetUpstreamShortSha)에 대한 동기화 점검 결과가 갱신되었습니다: $issueTitle" 2>$null
                } else {
                    Write-Warning "Failed to edit issue #$issueNum."
                }
            } else {
                Write-Host "    Creating new issue '$issueTitle'..." -ForegroundColor White
                & $ghCmd.Source issue create --repo $targetRepo --title $issueTitle --body $reportMarkdown --label "upstream-sync"
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "    Issue created successfully." -ForegroundColor Green
                } else {
                    Write-Warning "Failed to create GitHub issue."
                }
            }
        } else {
            Write-Warning "gh CLI not found; skipping GitHub issue publication."
        }
    } else {
        Write-Host "==> GitHub Issue reporting skipped (-NoIssue)." -ForegroundColor DarkGray
    }

    Write-Host "==> Watcher completed successfully." -ForegroundColor Green
    exit 0

} finally {
    # -------------------------------------------------------------------------
    # Cleanup temporary branches & restore workspace
    # -------------------------------------------------------------------------
    if ($tempTopicsFile -and (Test-Path $tempTopicsFile)) {
        Remove-Item -Path $tempTopicsFile -Force -ErrorAction SilentlyContinue
    }

    $gitDir = (& $gitExe rev-parse --git-dir 2>$null)
    if ($gitDir) {
        $gitDir = $gitDir.Trim()
        $inRebase = (Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))
        if ($inRebase) {
            & $gitExe rebase --abort 2>$null
        }
        $inMerge = Test-Path (Join-Path $gitDir "MERGE_HEAD")
        if ($inMerge) {
            & $gitExe merge --abort 2>$null
        }

        # Return to original branch
        $curr = (& $gitExe branch --show-current 2>$null)
        if ($curr) { $curr = $curr.Trim() }
        if ($curr -and $curr -ne $originalBranch) {
            & $gitExe checkout $originalBranch 2>$null
        }

        # Delete all temporary branches
        foreach ($tb in $createdTempBranches) {
            & $gitExe branch -D $tb 2>$null
        }
    }
}
