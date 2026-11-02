# gitui 포크(hj) 릴리스 가이드

본 문서는 gitui hj 포크 저장소(`5solas/gitui`)의 브랜치 모델, 버전 명명 규칙, 업스트림 동기화 절차, 로컬 및 GitHub Actions 릴리스 배포 방법, 그리고 Scoop 패키지 설치/업데이트 가이드를 설명합니다.

---

## 1. 버전 명명 규칙 (Version Scheme)

- **업스트림 기준 버전**: `Cargo.toml`의 `[package] version`을 추종합니다 (현재 `0.28.1`).
- **포크 버전 문자열 (Informational / SemVer)**: `<upstream>-hj-<N>` (예: `0.28.1-hj-1`)
  - 포크 번호 `<N>`은 `eng/hj/VERSION` 파일에서 관리되며 1부터 시작합니다.
  - 빌드 시 `GITUI_RELEASE=1` 환경 변수가 설정되면 `build.rs`가 `CARGO_PKG_VERSION`을 사용하므로, `gitui --version` 실행 시 `0.28.1-hj-1` 형식의 포크 버전이 정확히 출력됩니다.
- **MSI 버전**: `<major>.<minor>.<patch×100+N>` (예: `0.28.1` + hj-1 → `0.28.101`)
  - Windows Installer 는 4번째 자리를 무시하고 cargo-wix 는 X.Y.Z 만 받으므로, hj 번호를 패치 자리에 접어 `cargo wix --install-version` 으로 주입합니다. hj-N 업그레이드 순서가 유지되고 업스트림 MSI(0.28.1)보다 높고 다음 업스트림(0.28.2 → 0.28.201)보다 낮습니다. N 은 100 미만.
- **Git 태그 형식**: `hj/v<upstream>-hj-<N>` (예: `hj/v0.28.1-hj-1`)
  - annotated tag로 생성되며, 태그 메시지에 업스트림 베이스 커밋 정보(`upstream-base: <merge-base SHA>`)가 기록됩니다.

---

## 2. 브랜치 모델 (Branch Model)

포크 저장소는 업스트림과의 리베이스 용이성을 극대화하기 위해 패치 스택 모델을 따릅니다:

- **`master`**: 업스트림(`gitui-org/gitui`) `master`의 순수 미러 브랜치입니다. 직접 커밋하지 않습니다.
- **토픽 브랜치 (Topics)**: `master` 위에 리베이스되는 개별 기능/패치 브랜치입니다.
  - `feature/worktree`: 사용자가 개발하는 기능 브랜치
  - `hj/infra`: 포크 전용 인프라 및 릴리스 스크립트 관리 브랜치 (`eng/hj/`, `docs/hj/`, `.github/workflows/hj-release.yml`)
- **`hj/main`**: 포크 저장소의 기본 브랜치(Default branch)이자 통합 브랜치입니다.
  - 최신 `master`에서 시작하여 `eng/hj/topics.txt`에 명시된 토픽 브랜치들을 순서대로 `--no-ff` 머지하여 생성됩니다.
  - 업스트림 동기화 시마다 새로 생성되어 force-push됩니다.
- **리모트 저장소 구성**:
  - `upstream`: `https://github.com/gitui-org/gitui.git` (공식 원본 저장소)
  - `origin`: `https://github.com/5solas/gitui.git` (포크 저장소)

---

## 3. 업스트림 동기화 절차 (`eng/hj/Sync-Upstream.ps1`)

`Sync-Upstream.ps1` 스크립트는 업스트림 변경 사항을 가져와 모든 토픽 브랜치를 리베이스하고, 통합 브랜치 `hj/main`을 재생성합니다.

### 주요 기능
1. **작업 트리 검증**: 작업 트리가 깨끗한지 확인하고 다중 worktree 충돌을 방지합니다.
2. **임시 스크립트 재실행 (Self re-exec)**: 브랜치 전환 및 리베이스 도중 실행 중인 스크립트 파일이 잠기거나 변경되는 문제를 방지하기 위해 임시 디렉터리로 복사 후 실행합니다.
3. **안전 백업 생성**: 동기화 시작 전 모든 대상 브랜치의 참조를 `refs/hj-sync-backup/<timestamp>/<branch>`에 저장합니다. 실패 시 출력되는 복구 명령으로 즉시 원복 가능합니다.
4. **리모트 페치 & master 전진**: `upstream` 및 `origin`을 페치하고 `master`를 `upstream/master`로 fast-forward합니다.
5. **토픽 브랜치 리베이스 & rerere 지원**: `topics.txt` 순서대로 각 토픽을 `master` 위로 리베이스하며, 업스트림에 이미 반영된 커밋(`git cherry`)은 건너뜁니다.
6. **`hj/main` 통합 브랜치 재생성**: `master`에서 새 브랜치를 따서 각 토픽을 `--no-ff` 머지하고 통합 스파인 구조를 검증합니다.
7. **빌드 및 테스트 검증**: `cargo build` 및 `cargo test --workspace`를 수행하여 통합 결과물의 빌드/테스트를 검증합니다.
8. **원격 푸시 (`-Push`)**: 검증이 완료되면 `--force-with-lease`를 적용하여 `master`, 토픽 브랜치들, `hj/main`을 `origin`에 푸시합니다.

### 실행 예시
```pwsh
# 1. 안전 테스트 (DryRun: 실제 브랜치를 변경하지 않고 tmp/sync-* 브랜치로 검증)
pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1 -DryRun -SkipBuild -SkipTests

# 2. 로컬 동기화 및 빌드/테스트 검증
pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1

# 3. 동기화 성공 후 원격(origin)에 강제 푸시(--force-with-lease)
pwsh -NoProfile -File eng/hj/Sync-Upstream.ps1 -Push
```

---

## 4. 릴리스 절차 (Local & GitHub Actions)

### 단계 1: 로컬 준비 및 빌드 검증 (`Release.ps1`)

1. **`hj/main` 브랜치 체크아웃 및 최신화**:
   ```sh
   git checkout hj/main
   ```
2. **포크 번호 증가**:
   - `eng/hj/VERSION` 파일의 숫자를 1 증가시킵니다 (예: `1` -> `2`).
3. **로컬 패키징 및 태그 생성**:
   - 일반 릴리스 (빌드, 포터블 zip 및 WiX MSI 패키징, git 태그 생성):
     ```pwsh
     pwsh -NoProfile -File eng/hj/Release.ps1
     ```
   - 태그 생성 없이 패키징만 검증할 때:
     ```pwsh
     pwsh -NoProfile -File eng/hj/Release.ps1 -SkipTag
     ```
   - MSI 생성을 건너뛰고 포터블 zip만 생성할 때:
     ```pwsh
     pwsh -NoProfile -File eng/hj/Release.ps1 -SkipMsi
     ```
4. **산출물 확인**:
   - 산출물 경로: `target/hj/` (git 추적에서 제외됨)
     - `gitui-hj-win-x64-<ver>.zip`: 실행 파일(`gitui.exe`) 및 `LICENSE.md` 포함 포터블 압축 파일
     - `gitui-hj-win-x64-<ver>.msi`: Windows 설치 패키지
   - 실행 후 `Cargo.toml` 및 `Cargo.lock`의 스탬프가 자동으로 원복되어 `git status`가 깨끗하게 유지되는지 확인합니다.
5. **태그 및 브랜치 푸시**:
   ```sh
   git push origin hj/main
   git push origin hj/v0.28.1-hj-<N>
   ```

### 단계 2: GitHub Actions 자동 배포 (`.github/workflows/hj-release.yml`)

1. **자동 실행 (Tag Push)**:
   - `hj/v*` 태그가 푸시되면 `hj-release` 워크플로가 `windows-latest` 환경에서 자동으로 실행됩니다.
   - 워크플로는 Rust 툴체인 및 WiX 도구를 설정하고, `Cargo.toml`/`Cargo.lock` 버전을 스탬프한 후 릴리스 바이너리와 MSI를 빌드합니다.
   - 빌드된 실행 파일의 버전(`gitui.exe --version`)을 검증하고, SHA-256 체크섬을 계산합니다.
   - GitHub Release(`hj/v<ver>`)를 생성하고 zip 및 msi 자산을 업로드(`--clobber`)합니다.
   - 업스트림 태그(`v*`)에는 반응하지 않으며, 포크 태그(`hj/v*`)에만 동작합니다.
2. **수동 재실행 (workflow_dispatch)**:
   - GitHub 저장소 Actions 탭에서 **hj-release**를 선택하고 **Run workflow**를 통해 특정 태그(예: `hj/v0.28.1-hj-1`)에 대해 릴리스 빌드를 다시 트리거할 수 있습니다.

---

## 5. Scoop 패키지 설치 및 업데이트 가이드

hj 포크는 개인 버킷(`5solas/scoop-hj`)을 통해 간편하게 설치하고 관리할 수 있습니다:

### 1. 버킷 추가
```powershell
scoop bucket add hj https://github.com/5solas/scoop-hj
```

### 2. 설치
```powershell
scoop install hj/gitui-hj
```

### 3. 설치 확인
```powershell
gitui --version
# 출력: gitui 0.28.1-hj-1
```

### 4. 새 버전 업데이트
```powershell
scoop update gitui-hj
```
