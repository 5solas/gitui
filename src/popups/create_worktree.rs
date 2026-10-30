use crate::{
	app::Environment,
	components::{
		visibility_blocking, CommandBlocking, CommandInfo, Component,
		DrawableComponent, EventState, InputType, TextInputComponent,
	},
	keys::{key_match, SharedKeyConfig},
	queue::{InternalEvent, Queue},
	strings,
};
use anyhow::Result;
use asyncgit::sync::{self, RepoPathRef};
use crossterm::event::Event;
use ratatui::{layout::Rect, Frame};
use std::path::{Path, PathBuf};

pub struct CreateWorktreePopup {
	repo: RepoPathRef,
	input: TextInputComponent,
	queue: Queue,
	key_config: SharedKeyConfig,
}

impl DrawableComponent for CreateWorktreePopup {
	fn draw(&self, frame: &mut Frame, rect: Rect) -> Result<()> {
		if self.is_visible() {
			self.input.draw(frame, rect)?;
		}

		Ok(())
	}
}

impl Component for CreateWorktreePopup {
	fn commands(
		&self,
		out: &mut Vec<CommandInfo>,
		force_all: bool,
	) -> CommandBlocking {
		if self.is_visible() || force_all {
			self.input.commands(out, force_all);

			out.push(CommandInfo::new(
				strings::commands::create_worktree_confirm_msg(
					&self.key_config,
				),
				true,
				true,
			));
		}

		visibility_blocking(self)
	}

	fn event(&mut self, event: &Event) -> Result<EventState> {
		if self.is_visible() {
			if self.input.event(event)?.is_consumed() {
				return Ok(EventState::Consumed);
			}

			if let Event::Key(key_event) = event {
				if key_match(key_event, self.key_config.keys.enter) {
					self.create_worktree();
					return Ok(EventState::Consumed);
				}
			}
		}

		Ok(EventState::NotConsumed)
	}

	fn is_visible(&self) -> bool {
		self.input.is_visible()
	}

	fn hide(&mut self) {
		self.input.hide();
	}

	fn show(&mut self) -> Result<()> {
		self.input.show()?;

		Ok(())
	}
}

impl CreateWorktreePopup {
	pub fn new(env: &Environment) -> Self {
		Self {
			queue: env.queue.clone(),
			input: TextInputComponent::new(
				env,
				&strings::create_worktree_popup_title(
					&env.key_config,
				),
				&strings::create_worktree_popup_msg(&env.key_config),
				true,
			)
			.with_input_type(InputType::Singleline),
			key_config: env.key_config.clone(),
			repo: env.repo.clone(),
		}
	}

	pub fn open(&mut self) -> Result<()> {
		let default_path = self.default_worktree_path();
		self.input.set_text(default_path);
		self.show()?;

		Ok(())
	}

	fn default_worktree_path(&self) -> String {
		let repo_path = self.repo.borrow();
		let main_path = sync::get_worktrees(&repo_path)
			.ok()
			.and_then(|worktrees| {
				worktrees
					.into_iter()
					.find(|worktree| worktree.is_main)
					.map(|worktree| worktree.path)
			})
			.or_else(|| {
				sync::utils::repo_work_dir(&repo_path)
					.ok()
					.map(PathBuf::from)
			});

		if let Some(main_path) = main_path {
			let repo_dir_name = main_path
				.file_name()
				.and_then(|name| name.to_str())
				.unwrap_or("repo");
			if let Some(parent) = main_path.parent() {
				return parent
					.join(format!("{repo_dir_name}-wt"))
					.to_string_lossy()
					.to_string();
			}
		}

		String::new()
	}

	pub fn create_worktree(&mut self) {
		let input_path = self.input.get_text().trim().to_string();
		if input_path.is_empty() {
			return;
		}

		let result = sync::create_worktree(
			&self.repo.borrow(),
			Path::new(&input_path),
			None,
		);

		self.input.clear();
		self.hide();

		match result {
			Ok(()) => {
				self.queue.push(InternalEvent::WorktreesChanged);
			}
			Err(error) => {
				log::error!("create worktree: {error}");
				self.queue.push(InternalEvent::ShowErrorMsg(
					format!("create worktree error:\n{error}"),
				));
			}
		}
	}
}
