<#
.SYNOPSIS
    Syncs gitui topic branches and hj/main with upstream/master using patch-stack rebase.
.DESCRIPTION
    1. Validates working tree state, checks for worktree conflicts, and records original branch.
    2. Self-copies and re-executes from a temporary location to prevent file locking or modifications
       to the running script while switching and rebasing branches.
    3. Saves pre-sync backup refs under refs/hj-sync-backup/<timestamp>/<branch> for safe recovery.
    4. Fetches upstream and origin remotes.
    5. Fast-forwards master to upstream/master.
    6. Rebases each topic branch from topics.txt onto master (tracks skipped commits, handles rerere,
       verifies post-rebase ancestor and commit count consistency).
    7. Safely recreates hj/main using git checkout -B hj/main master without git reset --hard,
       merges each topic sequentially (--no-ff), and verifies integration spine ancestry.
    8. Optionally runs cargo build.
    9. Optionally runs cargo test --workspace.
   10. Summarizes changes (SHAs, commit counts, skipped commits, build/test results, backup recovery commands).
   11. Optionally pushes branches to origin (--force-with-lease for topics and hj/main).
   12. Restores original branch.
.PARAMETER Push
    Pushes master, topic branches, and hj/main to origin upon success.
.PARAMETER SkipTests
    Skips test execution.
.PARAMETER SkipBuild
    Skips cargo build step.
.PARAMETER Topics
    Path to topics list file (default: hj/infra:eng/hj/topics.txt with fallback to eng/hj/topics.txt).
.PARAMETER DryRun
    Tests rebase and merge using temporary branches (tmp/sync-*) without altering real branches.
.PARAMETER AllowDirty
    Kept for compatibility; has no effect. The working tree must be clean.
#>

[CmdletBinding()]
param(
    [switch]$Push,
    [switch]$SkipTests,
    [switch]$SkipBuild,
    [string]$Topics,
    [switch]$DryRun,
    [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Re-exec from a temporary directory copy so that branch checkouts and rebases
# do not overwrite, delete, or lock the executing script file itself.
# -----------------------------------------------------------------------------
if (-not $env:HJ_SYNC_REEXEC) {
    $scriptFile = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($scriptFile -and (Test-Path -Path $scriptFile -PathType Leaf)) {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("hj-sync-" + [Guid]::NewGuid().ToString("N"))
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

        $env:HJ_SYNC_REEXEC = "1"
        try {
            & pwsh -NoProfile -File $tempScript @forwardArgs
            $exitCode = $LASTEXITCODE
            exit $exitCode
        } finally {
            Remove-Item env:HJ_SYNC_REEXEC -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

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

# Resolve repository root
$repoRoot = (& $gitExe rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    Write-Error "Not inside a git repository."
    exit 1
}
$repoRoot = $repoRoot.Trim()
Set-Location $repoRoot

# Resolve topics file path
$tempTopicsFile = $null
$topicsSourceDescription = $null
$resolvedTopicsPath = $null

if ($PSBoundParameters.ContainsKey('Topics') -and -not [string]::IsNullOrWhiteSpace($Topics)) {
    # Custom topics file specified via -Topics
    $topicsSourceDescription = $Topics
    $resolvedTopicsPath = if ([System.IO.Path]::IsPathRooted($Topics)) { $Topics } else { Join-Path $repoRoot $Topics }
    if (-not (Test-Path $resolvedTopicsPath)) {
        Write-Error "Topics file not found at: $resolvedTopicsPath"
        exit 1
    }
} else {
    # Default: read topics from hj/infra branch (hj/infra:eng/hj/topics.txt)
    $infraTopics = & $gitExe show "hj/infra:eng/hj/topics.txt" 2>$null
    if ($LASTEXITCODE -eq 0 -and $infraTopics) {
        $tempTopicsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("hj-topics-" + [Guid]::NewGuid().ToString("N") + ".txt")
        Set-Content -Path $tempTopicsFile -Value $infraTopics -Encoding utf8
        $resolvedTopicsPath = $tempTopicsFile
        $topicsSourceDescription = "hj/infra:eng/hj/topics.txt"
    } else {
        Write-Warning "Could not read topics from 'hj/infra:eng/hj/topics.txt'. Falling back to working tree 'eng/hj/topics.txt'."
        $fallbackTopics = Join-Path $repoRoot "eng/hj/topics.txt"
        if (-not (Test-Path $fallbackTopics)) {
            Write-Error "Topics file not found at: $fallbackTopics"
            exit 1
        }
        $resolvedTopicsPath = $fallbackTopics
        $topicsSourceDescription = "eng/hj/topics.txt"
    }
}

# Read topic list (ignoring empty lines and comments)
$topicLines = @(Get-Content -Path $resolvedTopicsPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($topicLines.Count -eq 0) {
    Write-Error "No topic branches specified in $topicsSourceDescription."
    exit 1
}

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Test-ConflictMarkersPresent([string]$FilePath) {
    if (-not (Test-Path $FilePath)) {
        return $false
    }
    # Check for conflict marker lines starting with <<<<<<<
    $match = Select-String -Path $FilePath -Pattern '^<{7}(\s|$)' -Quiet -ErrorAction SilentlyContinue
    return [bool]$match
}

function Get-CheckedOutWorktrees {
    $result = @{}
    $lines = @(& $gitExe worktree list --porcelain 2>$null)
    $currentPath = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree\s+(.+)$') {
            $currentPath = $Matches[1].Trim()
        } elseif ($line -match '^branch\s+refs/heads/(.+)$') {
            $branch = $Matches[1].Trim()
            if ($currentPath) {
                $normPath = [System.IO.Path]::GetFullPath($currentPath)
                $result[$branch] = $normPath
            }
        }
    }
    return $result
}

function Assert-NoExternalWorktreeConflicts([string[]]$BranchesToCheck, [string]$RepoRootPath) {
    $worktrees = Get-CheckedOutWorktrees
    $currentRootNorm = [System.IO.Path]::GetFullPath($RepoRootPath)

    foreach ($branch in $BranchesToCheck) {
        if ($worktrees.ContainsKey($branch)) {
            $wtPath = $worktrees[$branch]
            if ($wtPath -ne $currentRootNorm) {
                Write-Error "Cannot proceed: branch '$branch' is currently checked out in another worktree at '$wtPath'. Please switch that worktree to a different branch before running sync."
                exit 1
            }
        }
    }
}

function Create-BackupRefs([string[]]$Branches, [string]$Timestamp) {
    $created = [System.Collections.Generic.Dictionary[string, string]]::new()
    foreach ($b in $Branches) {
        $sha = (& $gitExe rev-parse --verify "refs/heads/$b" 2>$null)
        if ($sha) {
            $sha = $sha.Trim()
            $refName = "refs/hj-sync-backup/$Timestamp/$b"
            & $gitExe update-ref $refName $sha
            if ($LASTEXITCODE -eq 0) {
                $created[$b] = $refName
            } else {
                Write-Error "Failed to create backup ref '$refName' for branch '$b'."
                exit 1
            }
        }
    }
    return $created
}

function Write-BackupRecoveryCommands([System.Collections.Generic.Dictionary[string, string]]$Refs, [string]$Timestamp) {
    if (-not $Refs -or $Refs.Count -eq 0) { return }
    Write-Host ""
    Write-Host "Backup references created under 'refs/hj-sync-backup/$Timestamp/':" -ForegroundColor Cyan
    Write-Host "To revert branches to their pre-sync state, execute:" -ForegroundColor Cyan
    foreach ($kvp in $Refs.GetEnumerator()) {
        Write-Host "  git branch -f $($kvp.Key) $($kvp.Value)" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Resolve-RerereOrHaltRebase(
    [string]$TopicName,
    [string]$OntoRef,
    [System.Collections.Generic.Dictionary[string, string]]$BackupRefs,
    [string]$BackupTimestamp
) {
    $gitDir = (& $gitExe rev-parse --git-dir).Trim()

    while ($true) {
        $inRebase = (Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))
        if (-not $inRebase) {
            break
        }

        $unmergedFiles = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
        $rerereStatus = @(& $gitExe rerere status 2>$null | Where-Object { $_.Trim() })

        $hasConflictMarkers = $false
        foreach ($file in $unmergedFiles) {
            if (Test-ConflictMarkersPresent $file) {
                $hasConflictMarkers = $true
                break
            }
        }

        # If no conflict markers remain and rerere has cleared or resolved them
        if (-not $hasConflictMarkers -and $rerereStatus.Count -eq 0) {
            Write-Host "[rerere] Automatically resolved conflicts for '$TopicName'. Continuing rebase..." -ForegroundColor Yellow
            & $gitExe add -A
            $env:GIT_EDITOR = 'true'
            $continueOutput = & $gitExe rebase --continue 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[rerere] Rebase completed successfully." -ForegroundColor Green
                break
            }
            continue
        }

        # Manual resolution required
        Write-Host ""
        Write-Host "=================================================================" -ForegroundColor Red
        Write-Host "CONFLICT DETECTED while rebasing '$TopicName' onto '$OntoRef'" -ForegroundColor Red
        Write-Host "=================================================================" -ForegroundColor Red
        Write-Host "Conflicting files:" -ForegroundColor Yellow
        $unmergedFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Resolve conflicts in the files listed above."
        Write-Host "  2. Stage resolved files: git add <file>"
        Write-Host "  3. Continue rebase:     git rebase --continue"
        Write-Host "  4. Re-run sync:         pwsh eng/hj/Sync-Upstream.ps1"
        Write-Host ""
        Write-BackupRecoveryCommands -Refs $BackupRefs -Timestamp $BackupTimestamp
        exit 2
    }
}

function Resolve-RerereOrHaltMerge(
    [string]$TopicName,
    [System.Collections.Generic.Dictionary[string, string]]$BackupRefs,
    [string]$BackupTimestamp
) {
    $unmergedFiles = @(& $gitExe diff --name-only --diff-filter=U 2>$null | Where-Object { $_.Trim() })
    $rerereStatus = @(& $gitExe rerere status 2>$null | Where-Object { $_.Trim() })

    $hasConflictMarkers = $false
    foreach ($file in $unmergedFiles) {
        if (Test-ConflictMarkersPresent $file) {
            $hasConflictMarkers = $true
            break
        }
    }

    if (-not $hasConflictMarkers -and $rerereStatus.Count -eq 0) {
        Write-Host "[rerere] Automatically resolved merge conflicts for '$TopicName'. Committing..." -ForegroundColor Yellow
        & $gitExe add -A
        & $gitExe commit --no-edit
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host "CONFLICT DETECTED while merging '$TopicName' into hj/main" -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host "Conflicting files:" -ForegroundColor Yellow
    $unmergedFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Resolve conflicts in the files listed above."
    Write-Host "  2. Stage resolved files: git add <file>"
    Write-Host "  3. Commit merge:        git commit --no-edit"
    Write-Host "  4. Re-run sync:         pwsh eng/hj/Sync-Upstream.ps1"
    Write-Host ""
    Write-BackupRecoveryCommands -Refs $BackupRefs -Timestamp $BackupTimestamp
    exit 2
}

# -----------------------------------------------------------------------------
# Step A: Validate Working Tree & Record Current Branch
# -----------------------------------------------------------------------------

# The script checks out and rebases branches in this worktree, so it must start clean.
# Stash is deliberately avoided because stash is shared across worktrees.
$statusOutput = @(& $gitExe status --porcelain 2>$null | Where-Object { $_.Trim() })
$trackedModifications = @($statusOutput | Where-Object { -not $_.StartsWith('??') })

if ($trackedModifications.Count -gt 0) {
    Write-Error "Working tree has local modifications. Commit or revert them before running sync.`n$($trackedModifications -join "`n")"
    exit 1
}

# Verify no branches to be altered are checked out in other worktrees
$branchesToValidate = [System.Collections.Generic.List[string]]::new()
$branchesToValidate.Add("master")
foreach ($t in $topicLines) {
    if (-not $branchesToValidate.Contains($t)) {
        $branchesToValidate.Add($t)
    }
}
if (-not $DryRun) {
    if (-not $branchesToValidate.Contains("hj/main")) {
        $branchesToValidate.Add("hj/main")
    }
}
Assert-NoExternalWorktreeConflicts -BranchesToCheck $branchesToValidate.ToArray() -RepoRootPath $repoRoot

$originalBranch = (& $gitExe branch --show-current 2>$null)
if ($originalBranch) {
    $originalBranch = $originalBranch.Trim()
}
if (-not $originalBranch) {
    $originalBranch = (& $gitExe rev-parse HEAD 2>$null).Trim()
}

$createdTempBranches = [System.Collections.Generic.List[string]]::new()

# Create safety backup refs before altering any branches
$backupTimestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$backupRefs = Create-BackupRefs -Branches $branchesToValidate.ToArray() -Timestamp $backupTimestamp

try {
    # -------------------------------------------------------------------------
    # Step B: Fetch Remotes
    # -------------------------------------------------------------------------
    Write-Host "==> [1/6] Fetching remotes (upstream, origin)..." -ForegroundColor Cyan
    & $gitExe fetch upstream --prune --tags
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch upstream remote."
        Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
        exit 1
    }
    & $gitExe fetch origin --prune
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch origin remote."
        Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
        exit 1
    }

    # -------------------------------------------------------------------------
    # Step C: Fast-Forward master to upstream/master
    # -------------------------------------------------------------------------
    Write-Host "==> [2/6] Fast-forwarding master to upstream/master..." -ForegroundColor Cyan
    $masterBeforeSha = (& $gitExe rev-parse master 2>$null).Trim()
    $upstreamMasterSha = (& $gitExe rev-parse upstream/master 2>$null).Trim()

    & $gitExe merge-base --is-ancestor master upstream/master
    if ($LASTEXITCODE -ne 0) {
        Write-Error "master cannot be fast-forwarded to upstream/master. Direct commits may exist on master."
        Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
        exit 1
    }

    $hasUpstreamChanges = ($masterBeforeSha -ne $upstreamMasterSha)
    if (-not $hasUpstreamChanges) {
        Write-Host "    Upstream master has no new commits ($masterBeforeSha). [변경 없음]" -ForegroundColor Yellow
    } else {
        Write-Host "    Upstream master updated: $masterBeforeSha -> $upstreamMasterSha" -ForegroundColor Cyan
    }

    if (-not $DryRun) {
        if ($originalBranch -eq 'master') {
            & $gitExe merge --ff-only upstream/master
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to fast-forward checked out master branch."
                Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
                exit 1
            }
        } else {
            & $gitExe branch -f master upstream/master
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to update master branch pointer."
                Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
                exit 1
            }
        }
        $masterAfterSha = (& $gitExe rev-parse master 2>$null).Trim()
    } else {
        $masterAfterSha = $upstreamMasterSha
        Write-Host "    [DryRun] master target SHA: $masterAfterSha" -ForegroundColor DarkGray
    }

    # -------------------------------------------------------------------------
    # Step D & E: Rebase Topic Branches onto master
    # -------------------------------------------------------------------------
    Write-Host "==> [3/6] Rebasing topic branches onto master..." -ForegroundColor Cyan
    $topicResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $rebaseOntoBase = if ($DryRun) { $upstreamMasterSha } else { "master" }

    foreach ($topic in $topicLines) {
        Write-Host "--- Processing topic: $topic" -ForegroundColor White
        $beforeSha = (& $gitExe rev-parse $topic 2>$null)
        if (-not $beforeSha) {
            Write-Error "Topic branch '$topic' does not exist in repository."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }
        $beforeSha = $beforeSha.Trim()
        $beforeCount = [int](& $gitExe rev-list --count "$rebaseOntoBase..$topic" 2>$null).Trim()

        # Identify commits that upstream has already adopted (git cherry)
        $cherryLines = @(& $gitExe cherry $rebaseOntoBase $topic 2>$null)
        $skippedCommits = [System.Collections.Generic.List[string]]::new()
        foreach ($cLine in $cherryLines) {
            if ($cLine -match '^-\s+([0-9a-fA-F]+)') {
                $cSha = $Matches[1]
                $cSummary = (& $gitExe log -1 --format="%h %s" $cSha 2>$null).Trim()
                $skippedCommits.Add($cSummary)
            }
        }

        if ($skippedCommits.Count -gt 0) {
            Write-Host "    Upstream already adopted $($skippedCommits.Count) commit(s) (will be skipped):" -ForegroundColor Yellow
            foreach ($s in $skippedCommits) {
                Write-Host "      - $s" -ForegroundColor Yellow
            }
        }

        $targetBranch = $topic
        if ($DryRun) {
            $safeName = $topic -replace '[^a-zA-Z0-9_\-]', '-'
            $targetBranch = "tmp/sync-$safeName"
            & $gitExe branch -f $targetBranch $topic
            $createdTempBranches.Add($targetBranch)
            Write-Host "    [DryRun] Created test branch '$targetBranch' for rebase" -ForegroundColor DarkGray
            & $gitExe checkout $targetBranch
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to checkout temporary test branch '$targetBranch'."
                Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
                exit 1
            }
        }

        # Perform rebase onto master / target upstream
        & $gitExe rebase $rebaseOntoBase $targetBranch
        $rebaseExitCode = $LASTEXITCODE
        if ($rebaseExitCode -ne 0) {
            $gitDir = (& $gitExe rev-parse --git-dir).Trim()
            $inRebase = (Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))
            if ($inRebase) {
                Resolve-RerereOrHaltRebase -TopicName $targetBranch -OntoRef $rebaseOntoBase -BackupRefs $backupRefs -BackupTimestamp $backupTimestamp
            } else {
                Write-Host ""
                Write-Host "ERROR: git rebase $rebaseOntoBase $targetBranch failed (exit code $rebaseExitCode) without entering rebase state." -ForegroundColor Red
                Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
                exit 1
            }
        }

        $afterSha = (& $gitExe rev-parse $targetBranch 2>$null).Trim()
        $afterCount = [int](& $gitExe rev-list --count "$rebaseOntoBase..$targetBranch" 2>$null).Trim()

        # Step D/E Verification:
        # 1. master must be an ancestor of topic after rebase
        & $gitExe merge-base --is-ancestor $rebaseOntoBase $targetBranch
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Rebase verification failed: $rebaseOntoBase is not an ancestor of '$targetBranch' after rebase."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }

        # 2. Commit count check: afterCount must equal beforeCount - skippedCommits.Count
        $expectedCount = $beforeCount - $skippedCommits.Count
        if ($afterCount -ne $expectedCount) {
            Write-Error "Rebase verification failed for '$topic': expected $expectedCount commit(s) ($beforeCount before minus $($skippedCommits.Count) upstream-adopted), but found $afterCount commit(s)."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }

        # Check if topic is now empty (identical to master / upstream)
        $isAdopted = ($afterCount -eq 0 -or $afterSha -eq $upstreamMasterSha)
        if ($isAdopted) {
            Write-Warning "Topic '$topic' is fully adopted upstream - consider removing it from $topicsSourceDescription"
        }

        $topicStatus = "Rebased"
        if ($isAdopted) {
            $topicStatus = "Adopted (Empty)"
        } elseif ($beforeSha -eq $afterSha) {
            & $gitExe merge-base --is-ancestor $rebaseOntoBase $beforeSha
            if ($LASTEXITCODE -eq 0) {
                $topicStatus = "Up to date (변경 없음)"
            } else {
                Write-Error "Rebase anomaly detected for '$topic': SHA unchanged ($beforeSha) but topic was not an ancestor of $rebaseOntoBase."
                Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
                exit 1
            }
        }

        $topicResults.Add([PSCustomObject]@{
            Topic              = $topic
            TargetBranch       = $targetBranch
            BeforeSha          = $beforeSha
            AfterSha           = $afterSha
            BeforeCommitCount  = $beforeCount
            AfterCommitCount   = $afterCount
            SkippedCommits     = $skippedCommits.ToArray()
            IsFullyAdopted     = $isAdopted
            Status             = $topicStatus
        })
    }

    # -------------------------------------------------------------------------
    # Step F: Recreate hj/main and Merge Topic Branches
    # -------------------------------------------------------------------------
    Write-Host "==> [4/6] Recreating hj/main and merging topics..." -ForegroundColor Cyan

    $mainBranch = if ($DryRun) { "tmp/sync-hj-main" } else { "hj/main" }
    $mainBase = if ($DryRun) { $upstreamMasterSha } else { "master" }

    if ($DryRun) {
        $createdTempBranches.Add($mainBranch)
        & $gitExe checkout -B $mainBranch $mainBase
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to checkout temporary integration branch '$mainBranch'."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }
    } else {
        Assert-NoExternalWorktreeConflicts -BranchesToCheck @("hj/main") -RepoRootPath $repoRoot
        & $gitExe checkout -B $mainBranch master
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to checkout and recreate $mainBranch from master."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }
    }

    foreach ($tr in $topicResults) {
        if ($tr.IsFullyAdopted) {
            Write-Host "    Skipping fully adopted topic '$($tr.Topic)' from merge" -ForegroundColor DarkGray
            continue
        }

        Write-Host "    Merging '$($tr.TargetBranch)' into $mainBranch (--no-ff)..." -ForegroundColor White
        & $gitExe merge --no-ff --no-edit $tr.TargetBranch
        if ($LASTEXITCODE -ne 0) {
            Resolve-RerereOrHaltMerge -TopicName $tr.TargetBranch -BackupRefs $backupRefs -BackupTimestamp $backupTimestamp
        }
    }

    $newHjMainSha = (& $gitExe rev-parse $mainBranch 2>$null).Trim()

    # Step F Verification:
    # 1. All topic branches must be ancestors of hj/main
    foreach ($tr in $topicResults) {
        if ($tr.IsFullyAdopted) {
            continue
        }
        & $gitExe merge-base --is-ancestor $tr.TargetBranch $mainBranch
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Integration branch verification failed: topic '$($tr.Topic)' is not an ancestor of $mainBranch."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }
    }

    # 2. For every topic with unique commits (master..topic count > 0), a merge commit must exist in hj/main's first-parent chain
    $firstParentMerges = @(& $gitExe log --first-parent --merges --format="%H %P" "$mainBase..$mainBranch" 2>$null)
    $secondParents = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($mLine in $firstParentMerges) {
        $parts = $mLine.Trim() -split '\s+'
        if ($parts.Count -ge 3) {
            [void]$secondParents.Add($parts[2])
        }
    }

    foreach ($tr in $topicResults) {
        if ($tr.IsFullyAdopted -or $tr.AfterCommitCount -eq 0) {
            continue
        }
        $targetTip = (& $gitExe rev-parse $tr.TargetBranch 2>$null).Trim()
        $found = $false
        foreach ($sp in $secondParents) {
            & $gitExe merge-base --is-ancestor $targetTip $sp
            if ($LASTEXITCODE -eq 0) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            Write-Error "Integration branch verification failed: topic '$($tr.Topic)' has unique commits ($($tr.AfterCommitCount)) but no merge commit was found on the first-parent spine of $mainBranch."
            Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
            exit 1
        }
    }

    # -------------------------------------------------------------------------
    # Step G: Build Verification (cargo build)
    # -------------------------------------------------------------------------
    if (-not $SkipBuild) {
        Write-Host "==> [5/6] Building project (cargo build)..." -ForegroundColor Cyan
        & $cargoExe build
        if ($LASTEXITCODE -ne 0) {
            Write-Error "cargo build failed with exit code $LASTEXITCODE."
            exit 1
        }
        Write-Host "    Build succeeded." -ForegroundColor Green
    } else {
        Write-Host "==> [5/6] Build skipped (-SkipBuild)." -ForegroundColor DarkGray
    }

    # -------------------------------------------------------------------------
    # Step H: Test Verification (cargo test --workspace)
    # -------------------------------------------------------------------------
    if (-not $SkipTests) {
        Write-Host "==> [6/6] Running tests (cargo test --workspace)..." -ForegroundColor Cyan
        & $cargoExe test --workspace
        if ($LASTEXITCODE -ne 0) {
            Write-Error "cargo test failed with exit code $LASTEXITCODE."
            exit 1
        }
        Write-Host "    All workspace tests passed." -ForegroundColor Green
    } else {
        Write-Host "==> [6/6] Tests skipped (-SkipTests)." -ForegroundColor DarkGray
    }

    # -------------------------------------------------------------------------
    # Step I: Result Summary
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "===============================================================================" -ForegroundColor Green
    Write-Host "                            UPSTREAM SYNC SUMMARY" -ForegroundColor Green
    Write-Host "===============================================================================" -ForegroundColor Green
    Write-Host "Master Branch:" -ForegroundColor White
    Write-Host "  Previous SHA : $masterBeforeSha"
    Write-Host "  New SHA      : $masterAfterSha"
    if (-not $hasUpstreamChanges) {
        Write-Host "  Upstream Sync: 변경 없음 (Already up-to-date with upstream/master)" -ForegroundColor Yellow
    } else {
        Write-Host "  Upstream Sync: $masterBeforeSha -> $masterAfterSha" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "Topic Branches:" -ForegroundColor White
    Write-Host "Topics source: $topicsSourceDescription ($($topicLines.Count) topics)"
    $topicSummaryView = $topicResults | Select-Object @{N="Topic";E={$_.Topic}},
        @{N="Before SHA";E={$_.BeforeSha.Substring(0, [System.Math]::Min(9, $_.BeforeSha.Length))}},
        @{N="After SHA";E={$_.AfterSha.Substring(0, [System.Math]::Min(9, $_.AfterSha.Length))}},
        @{N="Commits";E={"$($_.BeforeCommitCount) -> $($_.AfterCommitCount)"}},
        @{N="Skipped (Adopted)";E={$_.SkippedCommits.Count}},
        @{N="Status";E={$_.Status}}
    $topicSummaryView | Format-Table -AutoSize | Out-String | Write-Host

    $allSkipped = @($topicResults | ForEach-Object { $_.SkippedCommits } | Where-Object { $_ })
    if ($allSkipped.Count -gt 0) {
        Write-Host "Skipped (Upstream-Adopted) Commits:" -ForegroundColor Yellow
        foreach ($s in $allSkipped) {
            Write-Host "  - $s" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "hj/main Integration Branch:" -ForegroundColor White
    Write-Host "  New SHA      : $newHjMainSha"
    Write-Host ""

    if (-not $DryRun) {
        Write-BackupRecoveryCommands -Refs $backupRefs -Timestamp $backupTimestamp
    }

    # -------------------------------------------------------------------------
    # Step J: Push to Origin
    # -------------------------------------------------------------------------
    if ($Push) {
        if ($DryRun) {
            Write-Host "[DryRun] -Push specified but skipped due to -DryRun mode." -ForegroundColor DarkGray
        } else {
            Write-Host ""
            Write-Host "==> Pushing updated branches to origin..." -ForegroundColor Cyan

            Write-Host "    Pushing master to origin..." -ForegroundColor White
            & $gitExe push origin master
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to push master to origin."
                exit 1
            }

            foreach ($tr in $topicResults) {
                $tName = $tr.Topic
                Write-Host "    Pushing $tName with force-with-lease..." -ForegroundColor White
                & $gitExe push "--force-with-lease=${tName}:origin/${tName}" origin "$tName"
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to push $tName to origin."
                    exit 1
                }
            }

            Write-Host "    Pushing hj/main with force-with-lease..." -ForegroundColor White
            & $gitExe push "--force-with-lease=hj/main:origin/hj/main" origin hj/main
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to push hj/main to origin."
                exit 1
            }

            Write-Host "==> All branches successfully pushed to origin." -ForegroundColor Green
        }
    }

} finally {
    # -------------------------------------------------------------------------
    # Cleanup Temporary Branches, Backup Refs & Restore Original Branch
    # -------------------------------------------------------------------------
    if ($tempTopicsFile -and (Test-Path $tempTopicsFile)) {
        Remove-Item -Path $tempTopicsFile -Force -ErrorAction SilentlyContinue
    }

    if ($DryRun -and $backupRefs -and $backupRefs.Count -gt 0) {
        foreach ($bRef in $backupRefs.Values) {
            & $gitExe update-ref -d $bRef 2>$null
        }
    }

    if ($createdTempBranches.Count -gt 0) {
        & $gitExe checkout $originalBranch 2>$null
        foreach ($tb in $createdTempBranches) {
            & $gitExe branch -D $tb 2>$null
        }
    }

    $gitDir = (& $gitExe rev-parse --git-dir 2>$null)
    if ($gitDir) {
        $gitDir = $gitDir.Trim()
        $inRebase = (Test-Path (Join-Path $gitDir "rebase-merge")) -or (Test-Path (Join-Path $gitDir "rebase-apply"))
        $inMerge = Test-Path (Join-Path $gitDir "MERGE_HEAD")

        if (-not $inRebase -and -not $inMerge) {
            $curr = (& $gitExe branch --show-current 2>$null)
            if ($curr) { $curr = $curr.Trim() }
            if ($curr -and $curr -ne $originalBranch) {
                Write-Host "Restoring original branch '$originalBranch'..." -ForegroundColor DarkGray
                & $gitExe checkout $originalBranch 2>$null
            }
        }
    }
}
