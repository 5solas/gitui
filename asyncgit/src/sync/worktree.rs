//! git worktree support

use std::path::{Path, PathBuf};

use super::{CommitId, RepoPath};
use crate::error::Result;

///
#[derive(Debug, Clone)]
pub struct WorktreeInfo {
	/// worktree name (`None` for the main worktree)
	pub name: Option<String>,
	/// absolute path of the worktree's working directory
	pub path: PathBuf,
	/// short name of the checked out branch (`None` if detached)
	pub branch: Option<String>,
	/// commit HEAD points to (`None` for unborn HEAD)
	pub head_id: Option<CommitId>,
	/// true for the main worktree of the repository
	pub is_main: bool,
	/// true if this is the worktree `repo_path` currently points to
	pub is_current: bool,
	/// true if the worktree is locked
	pub is_locked: bool,
	/// false if the worktree directory is missing (prunable)
	pub is_valid: bool,
}

/// list all worktrees of the repository `repo_path` belongs to.
/// the main worktree comes first, linked worktrees follow sorted by name.
pub fn get_worktrees(
	repo_path: &RepoPath,
) -> Result<Vec<WorktreeInfo>> {
	let _ = repo_path;
	todo!()
}

/// create a new linked worktree at `path`.
/// if `branch` is `None`, a new branch named after the last path
/// component is created from HEAD (like `git worktree add <path>`).
/// if `branch` is `Some` and the local branch exists it is checked out,
/// otherwise a new branch with that name is created from HEAD.
pub fn create_worktree(
	repo_path: &RepoPath,
	path: &Path,
	branch: Option<&str>,
) -> Result<()> {
	let _ = (repo_path, path, branch);
	todo!()
}

/// remove the linked worktree `name` (its working directory and
/// administrative files). fails for locked worktrees unless `force`.
pub fn remove_worktree(
	repo_path: &RepoPath,
	name: &str,
	force: bool,
) -> Result<()> {
	let _ = (repo_path, name, force);
	todo!()
}

/// prune administrative files of worktrees whose directory is gone
pub fn prune_worktrees(repo_path: &RepoPath) -> Result<()> {
	let _ = repo_path;
	todo!()
}
