//! git worktree support

use std::path::{Path, PathBuf};

use git2::{
	BranchType, Repository, WorktreeAddOptions, WorktreeLockStatus,
	WorktreePruneOptions,
};
use scopetime::scope_time;

use super::{repo, CommitId, RepoPath};
use crate::{error::Result, Error};

///
#[allow(clippy::struct_excessive_bools)]
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

fn clean_path(path: &Path) -> PathBuf {
	let absolute_path = if path.is_absolute() {
		path.to_path_buf()
	} else if let Ok(current_directory) = std::env::current_dir() {
		current_directory.join(path)
	} else {
		path.to_path_buf()
	};

	let Some(path_str) = absolute_path.to_str() else {
		return absolute_path;
	};

	#[cfg(windows)]
	let path_string = path_str.replace('/', "\\");
	#[cfg(windows)]
	let str_slice = path_string.as_str();
	#[cfg(not(windows))]
	let str_slice = path_str;

	let str_slice = if let Some(stripped) =
		str_slice.strip_prefix(r"\\?\UNC\")
	{
		let trimmed = stripped.trim_end_matches(['/', '\\']);
		return PathBuf::from(format!(r"\\{trimmed}"));
	} else if let Some(stripped) = str_slice.strip_prefix(r"\\?\") {
		stripped
	} else {
		str_slice
	};

	let trimmed = str_slice.trim_end_matches(['/', '\\']);
	if trimmed.ends_with(':') {
		PathBuf::from(format!("{trimmed}\\"))
	} else if trimmed.is_empty() {
		PathBuf::from("/")
	} else {
		PathBuf::from(trimmed)
	}
}

fn paths_equal(path_first: &Path, path_second: &Path) -> bool {
	let cleaned_first = clean_path(path_first);
	let cleaned_second = clean_path(path_second);

	if cleaned_first == cleaned_second {
		return true;
	}

	let canonical_first = std::fs::canonicalize(&cleaned_first)
		.map_or_else(
			|_| cleaned_first.clone(),
			|canonical| clean_path(&canonical),
		);
	let canonical_second = std::fs::canonicalize(&cleaned_second)
		.map_or_else(
			|_| cleaned_second.clone(),
			|canonical| clean_path(&canonical),
		);

	if canonical_first == canonical_second {
		return true;
	}

	#[cfg(windows)]
	{
		canonical_first
			.to_string_lossy()
			.eq_ignore_ascii_case(&canonical_second.to_string_lossy())
			|| cleaned_first.to_string_lossy().eq_ignore_ascii_case(
				&cleaned_second.to_string_lossy(),
			)
	}
	#[cfg(not(windows))]
	{
		false
	}
}

fn get_branch_and_head(
	repository: &Repository,
) -> (Option<String>, Option<CommitId>) {
	let Ok(head_reference) = repository.head() else {
		return (None, None);
	};

	let branch = if head_reference.is_branch() {
		head_reference.shorthand().ok().map(String::from)
	} else {
		None
	};

	let head_id = head_reference.target().map(CommitId::from);

	(branch, head_id)
}

/// list all worktrees of the repository `repo_path` belongs to.
///
/// the main worktree comes first, linked worktrees follow sorted by name.
pub fn get_worktrees(
	repo_path: &RepoPath,
) -> Result<Vec<WorktreeInfo>> {
	scope_time!("get_worktrees");

	let repository = repo(repo_path)?;
	let current_workdir = repository.workdir().map(clean_path);

	let main_repository_storage;
	let main_repository = if repository.is_worktree() {
		main_repository_storage =
			Repository::open(repository.commondir())?;
		&main_repository_storage
	} else {
		&repository
	};

	let main_workdir =
		main_repository.workdir().ok_or(Error::NoWorkDir)?;
	let main_path = clean_path(main_workdir);
	let (main_branch, main_head_id) =
		get_branch_and_head(main_repository);
	let main_is_current = current_workdir
		.as_ref()
		.is_some_and(|current| paths_equal(current, &main_path));

	let mut worktree_list = Vec::new();
	worktree_list.push(WorktreeInfo {
		name: None,
		path: main_path.clone(),
		branch: main_branch,
		head_id: main_head_id,
		is_main: true,
		is_current: main_is_current,
		is_locked: false,
		is_valid: main_path.exists(),
	});

	let mut names: Vec<String> = main_repository
		.worktrees()?
		.iter()
		.filter_map(|item| item.ok().flatten())
		.map(String::from)
		.collect();
	names.sort();

	for worktree_name in names {
		let worktree =
			main_repository.find_worktree(&worktree_name)?;
		let worktree_path = clean_path(worktree.path());
		let is_locked = matches!(
			worktree.is_locked(),
			Ok(WorktreeLockStatus::Locked(_))
		);
		let is_valid = worktree.validate().is_ok();
		let (branch, head_id) = if is_valid {
			Repository::open_from_worktree(&worktree)
				.map_or((None, None), |worktree_repo| {
					get_branch_and_head(&worktree_repo)
				})
		} else {
			(None, None)
		};
		let is_current =
			current_workdir.as_ref().is_some_and(|current| {
				paths_equal(current, &worktree_path)
			});

		worktree_list.push(WorktreeInfo {
			name: Some(worktree_name),
			path: worktree_path,
			branch,
			head_id,
			is_main: false,
			is_current,
			is_locked,
			is_valid,
		});
	}

	Ok(worktree_list)
}

/// create a new linked worktree at `path`.
///
/// if `branch` is `None`, a new branch named after the last path
/// component is created from HEAD (like `git worktree add <path>`).
/// if `branch` is `Some` and the local branch exists it is checked out,
/// otherwise a new branch with that name is created from HEAD.
pub fn create_worktree(
	repo_path: &RepoPath,
	path: &Path,
	branch: Option<&str>,
) -> Result<()> {
	scope_time!("create_worktree");

	let repository = repo(repo_path)?;

	// relative paths are relative to the current workdir (like `git worktree add`),
	// not to the process cwd which can differ (`gitui -d <path>`)
	let cleaned_path = if path.is_absolute() {
		clean_path(path)
	} else {
		let workdir = repository.workdir().ok_or(Error::NoWorkDir)?;
		clean_path(&workdir.join(path))
	};
	let worktree_name = cleaned_path
		.file_name()
		.and_then(|name| name.to_str())
		.ok_or_else(|| {
			Error::Generic(format!(
				"invalid worktree path: {}",
				path.display()
			))
		})?;

	if cleaned_path.exists() {
		if cleaned_path.is_dir() {
			let mut directory_entries =
				std::fs::read_dir(&cleaned_path)?;
			if directory_entries.next().is_some() {
				return Err(Error::Generic(format!(
					"path already exists and is not empty: {}",
					cleaned_path.display()
				)));
			}
			std::fs::remove_dir(&cleaned_path)?;
		} else {
			return Err(Error::Generic(format!(
				"path already exists: {}",
				cleaned_path.display()
			)));
		}
	}

	let branch_name = branch.unwrap_or(worktree_name);

	let (branch_reference, branch_created) = if let Ok(local_branch) =
		repository.find_branch(branch_name, BranchType::Local)
	{
		(local_branch.into_reference(), false)
	} else {
		let head = repository.head()?;
		let head_commit = head.peel_to_commit()?;
		(
			repository
				.branch(branch_name, &head_commit, false)?
				.into_reference(),
			true,
		)
	};

	let mut options = WorktreeAddOptions::new();
	options.reference(Some(&branch_reference));

	if let Err(e) = repository.worktree(
		worktree_name,
		&cleaned_path,
		Some(&options),
	) {
		// do not leave a dangling branch behind that we just created
		if branch_created {
			if let Ok(mut created) =
				repository.find_branch(branch_name, BranchType::Local)
			{
				let _ = created.delete();
			}
		}
		return Err(e.into());
	}

	Ok(())
}

/// remove the linked worktree `name` (its working directory and
/// administrative files).
///
/// fails for locked worktrees unless `force`.
pub fn remove_worktree(
	repo_path: &RepoPath,
	name: &str,
	force: bool,
) -> Result<()> {
	scope_time!("remove_worktree");

	let repository = repo(repo_path)?;
	let worktree = repository.find_worktree(name)?;

	let is_locked = matches!(
		worktree.is_locked(),
		Ok(WorktreeLockStatus::Locked(_))
	);
	if is_locked && !force {
		return Err(Error::Generic("worktree is locked".into()));
	}

	let mut prune_options = WorktreePruneOptions::new();
	prune_options.valid(true).working_tree(true).locked(force);

	worktree.prune(Some(&mut prune_options))?;

	Ok(())
}

/// prune administrative files of worktrees whose directory is gone.
pub fn prune_worktrees(repo_path: &RepoPath) -> Result<()> {
	scope_time!("prune_worktrees");

	let repository = repo(repo_path)?;
	let worktree_names = repository.worktrees()?;

	for worktree_name in
		worktree_names.iter().filter_map(|item| item.ok().flatten())
	{
		let Ok(worktree) = repository.find_worktree(worktree_name)
		else {
			continue;
		};

		let is_locked = matches!(
			worktree.is_locked(),
			Ok(WorktreeLockStatus::Locked(_))
		);

		if worktree.validate().is_err() && !is_locked {
			worktree.prune(None)?;
		}
	}

	Ok(())
}

#[cfg(test)]
#[allow(
	clippy::unwrap_used,
	clippy::too_many_lines,
	clippy::similar_names,
	clippy::expect_used,
	clippy::panic
)]
mod tests {
	use super::*;
	use crate::sync::tests::repo_init;
	use pretty_assertions::assert_eq;
	use tempfile::TempDir;

	#[test]
	fn test_worktree_lifecycle() {
		let (temporary_directory, _repository) = repo_init().unwrap();
		let repo_path =
			RepoPath::Path(temporary_directory.path().to_path_buf());

		// 1. List on fresh repo: 1 main entry, is_current, branch Some
		let worktrees = get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees.len(), 1);
		assert!(worktrees[0].is_main);
		assert!(worktrees[0].is_current);
		assert_eq!(worktrees[0].name, None);
		assert!(worktrees[0].branch.is_some());
		assert!(worktrees[0].head_id.is_some());
		assert!(worktrees[0].is_valid);
		assert!(!worktrees[0].is_locked);

		// 2. Create worktree -> list has 2 with correct branch & is_valid
		let worktree_parent_dir = TempDir::new().unwrap();
		let worktree_path_first =
			worktree_parent_dir.path().join("worktree_first");
		create_worktree(&repo_path, &worktree_path_first, None)
			.unwrap();

		let worktrees = get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees.len(), 2);
		assert!(worktrees[0].is_main);
		assert!(worktrees[0].is_current);

		let first_linked = &worktrees[1];
		assert_eq!(
			first_linked.name.as_deref(),
			Some("worktree_first")
		);
		assert_eq!(
			first_linked.branch.as_deref(),
			Some("worktree_first")
		);
		assert!(first_linked.is_valid);
		assert!(!first_linked.is_main);
		assert!(!first_linked.is_current);
		assert_eq!(first_linked.head_id, worktrees[0].head_id);

		// 3. Create with existing branch name
		{
			let repository = repo(&repo_path).unwrap();
			let head =
				repository.head().unwrap().peel_to_commit().unwrap();
			repository
				.branch("existing_branch", &head, false)
				.unwrap();
		}
		let worktree_path_second =
			worktree_parent_dir.path().join("worktree_second");
		create_worktree(
			&repo_path,
			&worktree_path_second,
			Some("existing_branch"),
		)
		.unwrap();

		let worktrees = get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees.len(), 3);
		let second_linked = worktrees
			.iter()
			.find(|entry| {
				entry.name.as_deref() == Some("worktree_second")
			})
			.unwrap();
		assert_eq!(
			second_linked.branch.as_deref(),
			Some("existing_branch")
		);
		assert!(second_linked.is_valid);

		// 4. Open created worktree path as RepoPath and check is_current flips
		let worktree_repo_path =
			RepoPath::Path(worktree_path_first.clone());
		let worktrees_from_worktree =
			get_worktrees(&worktree_repo_path).unwrap();
		assert_eq!(worktrees_from_worktree.len(), 3);

		let main_from_worktree = worktrees_from_worktree
			.iter()
			.find(|entry| entry.is_main)
			.unwrap();
		assert!(!main_from_worktree.is_current);

		let first_from_worktree = worktrees_from_worktree
			.iter()
			.find(|entry| {
				entry.name.as_deref() == Some("worktree_first")
			})
			.unwrap();
		assert!(first_from_worktree.is_current);

		let second_from_worktree = worktrees_from_worktree
			.iter()
			.find(|entry| {
				entry.name.as_deref() == Some("worktree_second")
			})
			.unwrap();
		assert!(!second_from_worktree.is_current);

		// 5. Remove -> back to 1 and directory gone
		remove_worktree(&repo_path, "worktree_second", false)
			.unwrap();
		assert!(!worktree_path_second.exists());

		remove_worktree(&repo_path, "worktree_first", false).unwrap();
		assert!(!worktree_path_first.exists());

		let worktrees_after_remove =
			get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees_after_remove.len(), 1);
		assert!(worktrees_after_remove[0].is_main);

		// 6. Prune after manually deleting worktree dir
		let worktree_path_third =
			worktree_parent_dir.path().join("worktree_third");
		create_worktree(&repo_path, &worktree_path_third, None)
			.unwrap();
		assert!(worktree_path_third.exists());

		let worktrees_before_delete =
			get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees_before_delete.len(), 2);

		std::fs::remove_dir_all(&worktree_path_third).unwrap();
		assert!(!worktree_path_third.exists());

		let worktrees_missing = get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees_missing.len(), 2);
		let missing_entry = worktrees_missing
			.iter()
			.find(|entry| {
				entry.name.as_deref() == Some("worktree_third")
			})
			.unwrap();
		assert!(!missing_entry.is_valid);

		prune_worktrees(&repo_path).unwrap();

		let worktrees_after_prune =
			get_worktrees(&repo_path).unwrap();
		assert_eq!(worktrees_after_prune.len(), 1);
		assert!(worktrees_after_prune[0].is_main);

		// 7. Non-empty directory error test
		let non_empty_directory =
			worktree_parent_dir.path().join("non_empty");
		std::fs::create_dir(&non_empty_directory).unwrap();
		std::fs::write(
			non_empty_directory.join("file.txt"),
			"content",
		)
		.unwrap();
		let create_result =
			create_worktree(&repo_path, &non_empty_directory, None);
		assert!(create_result.is_err());

		// 7b. relative path resolves against the repo workdir
		create_worktree(&repo_path, Path::new("relative_wt"), None)
			.unwrap();
		assert!(temporary_directory
			.path()
			.join("relative_wt")
			.exists());
		remove_worktree(&repo_path, "relative_wt", false).unwrap();

		// 7c. failed add must not leave a newly created branch behind
		let other_parent_dir = TempDir::new().unwrap();
		create_worktree(
			&repo_path,
			&worktree_parent_dir.path().join("dup"),
			None,
		)
		.unwrap();
		// worktree name "dup" is taken -> add fails
		assert!(create_worktree(
			&repo_path,
			&other_parent_dir.path().join("dup"),
			Some("dup_branch"),
		)
		.is_err());
		assert!(repo(&repo_path)
			.unwrap()
			.find_branch("dup_branch", BranchType::Local)
			.is_err());
		remove_worktree(&repo_path, "dup", false).unwrap();

		// 8. Locked worktree removal test
		let worktree_path_locked =
			worktree_parent_dir.path().join("worktree_locked");
		create_worktree(&repo_path, &worktree_path_locked, None)
			.unwrap();
		{
			let repository = repo(&repo_path).unwrap();
			let worktree =
				repository.find_worktree("worktree_locked").unwrap();
			worktree.lock(Some("testing lock status")).unwrap();
		}
		let worktrees_locked = get_worktrees(&repo_path).unwrap();
		let locked_entry = worktrees_locked
			.iter()
			.find(|entry| {
				entry.name.as_deref() == Some("worktree_locked")
			})
			.unwrap();
		assert!(locked_entry.is_locked);

		let remove_result =
			remove_worktree(&repo_path, "worktree_locked", false);
		assert!(remove_result.is_err());

		remove_worktree(&repo_path, "worktree_locked", true).unwrap();
		assert!(!worktree_path_locked.exists());
	}
}
