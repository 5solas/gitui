use crate::{
	app::Environment,
	components::{
		visibility_blocking, CommandBlocking, CommandInfo, Component,
		DrawableComponent, EventState, ScrollType, VerticalScroll,
	},
	keys::{key_match, SharedKeyConfig},
	queue::{Action, InternalEvent, NeedsUpdate, Queue},
	strings, try_or_popup,
	ui::{self, Size},
};
use anyhow::Result;
use asyncgit::sync::{
	get_worktrees, prune_worktrees, RepoPathRef, WorktreeInfo,
};
use crossterm::event::Event;
use ratatui::{
	layout::{
		Alignment, Constraint, Direction, Layout, Margin, Rect,
	},
	text::{Line, Span, Text},
	widgets::{Block, Borders, Clear, Paragraph},
	Frame,
};
use std::cell::Cell;
use ui::style::SharedTheme;
use unicode_truncate::UnicodeTruncateStr;

pub struct WorktreesListPopup {
	repo: RepoPathRef,
	queue: Queue,
	worktrees: Vec<WorktreeInfo>,
	visible: bool,
	current_height: Cell<u16>,
	selection: u16,
	scroll: VerticalScroll,
	theme: SharedTheme,
	key_config: SharedKeyConfig,
}

impl DrawableComponent for WorktreesListPopup {
	fn draw(&self, frame: &mut Frame, rect: Rect) -> Result<()> {
		if self.is_visible() {
			const PERCENT_SIZE: Size = Size::new(80, 80);
			const MIN_SIZE: Size = Size::new(60, 20);

			let area = ui::centered_rect(
				PERCENT_SIZE.width,
				PERCENT_SIZE.height,
				rect,
			);
			let area = ui::rect_inside(MIN_SIZE, rect.into(), area);
			let area = area.intersection(rect);

			frame.render_widget(Clear, area);

			frame.render_widget(
				Block::default()
					.title(strings::POPUP_TITLE_WORKTREES)
					.border_type(ratatui::widgets::BorderType::Thick)
					.borders(Borders::ALL),
				area,
			);

			let inner_area = area.inner(Margin {
				vertical: 1,
				horizontal: 1,
			});

			let chunks = Layout::default()
				.direction(Direction::Horizontal)
				.constraints(
					[
						Constraint::Ratio(1, 2),
						Constraint::Ratio(1, 2),
					]
					.as_ref(),
				)
				.split(inner_area);

			self.draw_list(frame, chunks[0])?;
			self.draw_info(frame, chunks[1]);
		}

		Ok(())
	}
}

impl Component for WorktreesListPopup {
	fn commands(
		&self,
		out: &mut Vec<CommandInfo>,
		force_all: bool,
	) -> CommandBlocking {
		if self.visible || force_all {
			if !force_all {
				out.clear();
			}

			out.push(CommandInfo::new(
				strings::commands::scroll(&self.key_config),
				true,
				true,
			));

			out.push(CommandInfo::new(
				strings::commands::close_popup(&self.key_config),
				true,
				true,
			));

			out.push(CommandInfo::new(
				strings::commands::open_worktree(&self.key_config),
				self.can_open_worktree(),
				true,
			));

			out.push(CommandInfo::new(
				strings::commands::create_worktree(&self.key_config),
				true,
				true,
			));

			out.push(CommandInfo::new(
				strings::commands::delete_worktree(&self.key_config),
				self.can_delete_worktree(),
				true,
			));

			out.push(CommandInfo::new(
				strings::commands::prune_worktrees(&self.key_config),
				self.can_prune_worktrees(),
				true,
			));
		}

		visibility_blocking(self)
	}

	fn event(&mut self, event: &Event) -> Result<EventState> {
		if !self.visible {
			return Ok(EventState::NotConsumed);
		}

		if let Event::Key(key_event) = event {
			if key_match(key_event, self.key_config.keys.exit_popup) {
				self.hide();
			} else if key_match(
				key_event,
				self.key_config.keys.move_down,
			) {
				return self
					.move_selection(ScrollType::Up)
					.map(Into::into);
			} else if key_match(
				key_event,
				self.key_config.keys.move_up,
			) {
				return self
					.move_selection(ScrollType::Down)
					.map(Into::into);
			} else if key_match(
				key_event,
				self.key_config.keys.page_down,
			) {
				return self
					.move_selection(ScrollType::PageDown)
					.map(Into::into);
			} else if key_match(
				key_event,
				self.key_config.keys.page_up,
			) {
				return self
					.move_selection(ScrollType::PageUp)
					.map(Into::into);
			} else if key_match(key_event, self.key_config.keys.home)
			{
				return self
					.move_selection(ScrollType::Home)
					.map(Into::into);
			} else if key_match(key_event, self.key_config.keys.end) {
				return self
					.move_selection(ScrollType::End)
					.map(Into::into);
			} else if key_match(key_event, self.key_config.keys.enter)
			{
				if self.can_open_worktree() {
					if let Some(worktree) = self.selected_entry() {
						self.queue.push(InternalEvent::OpenRepo {
							path: worktree.path.clone(),
						});
					}
				}
			} else if key_match(
				key_event,
				self.key_config.keys.create_branch,
			) {
				self.queue.push(InternalEvent::CreateWorktree);
			} else if key_match(
				key_event,
				self.key_config.keys.delete_branch,
			) {
				if self.can_delete_worktree() {
					if let Some(worktree) = self.selected_entry() {
						if let Some(worktree_name) = &worktree.name {
							self.queue.push(
								InternalEvent::ConfirmAction(
									Action::DeleteWorktree(
										worktree_name.clone(),
									),
								),
							);
						}
					}
				}
			} else if key_match(
				key_event,
				self.key_config.keys.prune_worktrees,
			) {
				try_or_popup!(
					self,
					"prune worktrees:",
					prune_worktrees(&self.repo.borrow())
				);

				self.update_worktrees()?;

				self.queue
					.push(InternalEvent::Update(NeedsUpdate::ALL));
			} else if key_match(
				key_event,
				self.key_config.keys.cmd_bar_toggle,
			) {
				return Ok(EventState::NotConsumed);
			}
		}

		Ok(EventState::Consumed)
	}

	fn is_visible(&self) -> bool {
		self.visible
	}

	fn hide(&mut self) {
		self.visible = false;
	}

	fn show(&mut self) -> Result<()> {
		self.visible = true;

		Ok(())
	}
}

impl WorktreesListPopup {
	pub fn new(env: &Environment) -> Self {
		Self {
			worktrees: Vec::new(),
			scroll: VerticalScroll::new(),
			queue: env.queue.clone(),
			selection: 0,
			visible: false,
			theme: env.theme.clone(),
			key_config: env.key_config.clone(),
			current_height: Cell::new(0),
			repo: env.repo.clone(),
		}
	}

	pub fn open(&mut self) -> Result<()> {
		self.show()?;
		self.update_worktrees()?;

		Ok(())
	}

	pub fn update_worktrees(&mut self) -> Result<()> {
		if self.is_visible() {
			self.worktrees = get_worktrees(&self.repo.borrow())?;
			self.set_selection(self.selection)?;
		}
		Ok(())
	}

	fn selected_entry(&self) -> Option<&WorktreeInfo> {
		self.worktrees.get(self.selection as usize)
	}

	fn can_open_worktree(&self) -> bool {
		self.selected_entry().is_some_and(|worktree| {
			!worktree.is_current && worktree.is_valid
		})
	}

	fn can_delete_worktree(&self) -> bool {
		self.selected_entry().is_some_and(|worktree| {
			!worktree.is_main && !worktree.is_current
		})
	}

	fn can_prune_worktrees(&self) -> bool {
		self.worktrees.iter().any(|worktree| !worktree.is_valid)
	}

	fn move_selection(&mut self, scroll: ScrollType) -> Result<bool> {
		let new_selection = match scroll {
			ScrollType::Up => self.selection.saturating_add(1),
			ScrollType::Down => self.selection.saturating_sub(1),
			ScrollType::PageDown => self
				.selection
				.saturating_add(self.current_height.get()),
			ScrollType::PageUp => self
				.selection
				.saturating_sub(self.current_height.get()),
			ScrollType::Home => 0,
			ScrollType::End => {
				let count: u16 = self.worktrees.len().try_into()?;
				count.saturating_sub(1)
			}
		};

		self.set_selection(new_selection)?;

		Ok(true)
	}

	fn set_selection(&mut self, selection: u16) -> Result<()> {
		let number_of_entries: u16 =
			self.worktrees.len().try_into()?;
		let number_of_entries = number_of_entries.saturating_sub(1);

		let selection = if selection > number_of_entries {
			number_of_entries
		} else {
			selection
		};

		self.selection = selection;

		Ok(())
	}

	fn get_text(
		&self,
		theme: &SharedTheme,
		width_available: u16,
		height: usize,
	) -> Text<'_> {
		const THREE_DOTS: &str = "...";
		const THREE_DOTS_LENGTH: usize = THREE_DOTS.len();
		const COMMIT_HASH_LENGTH: usize = 8;
		const MARKER_LENGTH: usize = 2;

		let mut text_lines = Vec::with_capacity(self.worktrees.len());

		for (index, worktree) in self
			.worktrees
			.iter()
			.skip(self.scroll.get_top())
			.take(height)
			.enumerate()
		{
			let selected = (self.selection as usize
				- self.scroll.get_top())
				== index;

			let marker =
				if worktree.is_current { "* " } else { "  " };
			let span_marker = Span::styled(
				marker,
				theme.branch(selected, worktree.is_current),
			);

			let branch_str =
				worktree.branch.as_deref().unwrap_or("(detached)");

			let mut tags_len = 0;
			if worktree.is_locked {
				tags_len += 9;
			}
			if !worktree.is_valid {
				tags_len += 11;
			}

			let max_branch_len = (width_available as usize)
				.saturating_sub(MARKER_LENGTH)
				.saturating_sub(COMMIT_HASH_LENGTH)
				.saturating_sub(tags_len)
				.saturating_sub(1);

			let mut display_branch = branch_str.to_string();
			if display_branch.len() > max_branch_len
				&& max_branch_len > THREE_DOTS_LENGTH
			{
				display_branch.unicode_truncate(
					max_branch_len.saturating_sub(THREE_DOTS_LENGTH),
				);
				display_branch += THREE_DOTS;
			}

			let span_branch = Span::styled(
				format!("{display_branch} "),
				theme.branch(selected, worktree.is_current),
			);

			let hash_str = worktree.head_id.map_or_else(
				|| "       ".to_string(),
				|id| id.get_short_string(),
			);

			let span_hash = Span::styled(
				format!("{hash_str} "),
				theme.commit_hash(selected),
			);

			let mut spans = vec![span_marker, span_branch, span_hash];

			if worktree.is_locked {
				spans.push(Span::styled(
					"[locked] ",
					theme.tags(selected),
				));
			}

			if !worktree.is_valid {
				spans.push(Span::styled(
					"[prunable] ",
					theme.text_danger(),
				));
			}

			text_lines.push(Line::from(spans));
		}

		Text::from(text_lines)
	}

	fn get_info_text(&self, theme: &SharedTheme) -> Text<'_> {
		self.selected_entry()
			.map_or_else(Text::default, |worktree| {
				let span_title_name =
					Span::styled("Name:", theme.text(false, false));
				let name_string = if worktree.is_main {
					"(main)".to_string()
				} else {
					worktree.name.clone().unwrap_or_default()
				};
				let span_name = Span::styled(
					name_string,
					theme.text(true, false),
				);

				let span_title_path =
					Span::styled("Path:", theme.text(false, false));
				let span_path = Span::styled(
					worktree.path.to_string_lossy(),
					theme.text(true, false),
				);

				let span_title_branch =
					Span::styled("Branch:", theme.text(false, false));
				let branch_string = worktree
					.branch
					.clone()
					.unwrap_or_else(|| "(detached)".to_string());
				let span_branch = Span::styled(
					branch_string,
					theme.text(true, false),
				);

				let span_title_commit =
					Span::styled("Commit:", theme.text(false, false));
				let commit_string = worktree.head_id.map_or_else(
					|| "none".to_string(),
					|id| id.to_string(),
				);
				let span_commit = Span::styled(
					commit_string,
					theme.commit_hash(false),
				);

				let span_title_locked =
					Span::styled("Locked:", theme.text(false, false));
				let span_locked = Span::styled(
					if worktree.is_locked { "yes" } else { "no" },
					theme.text(true, false),
				);

				let span_title_valid =
					Span::styled("Valid:", theme.text(false, false));
				let span_valid = Span::styled(
					if worktree.is_valid {
						"yes"
					} else {
						"no (prunable)"
					},
					theme.text(true, false),
				);

				Text::from(vec![
					Line::from(vec![span_title_name]),
					Line::from(vec![span_name]),
					Line::from(vec![]),
					Line::from(vec![span_title_path]),
					Line::from(vec![span_path]),
					Line::from(vec![]),
					Line::from(vec![span_title_branch]),
					Line::from(vec![span_branch]),
					Line::from(vec![]),
					Line::from(vec![span_title_commit]),
					Line::from(vec![span_commit]),
					Line::from(vec![]),
					Line::from(vec![span_title_locked]),
					Line::from(vec![span_locked]),
					Line::from(vec![]),
					Line::from(vec![span_title_valid]),
					Line::from(vec![span_valid]),
				])
			})
	}

	fn draw_list(&self, frame: &mut Frame, rect: Rect) -> Result<()> {
		let height_in_lines = rect.height as usize;
		self.current_height.set(height_in_lines.try_into()?);

		self.scroll.update(
			self.selection as usize,
			self.worktrees.len(),
			height_in_lines,
		);

		frame.render_widget(
			Paragraph::new(self.get_text(
				&self.theme,
				rect.width.saturating_sub(1),
				height_in_lines,
			))
			.block(Block::default().borders(Borders::RIGHT))
			.alignment(Alignment::Left),
			rect,
		);

		let mut scroll_rect = rect;
		scroll_rect.height += 2;
		scroll_rect.y = scroll_rect.y.saturating_sub(1);

		self.scroll.draw(frame, scroll_rect, &self.theme);

		Ok(())
	}

	fn draw_info(&self, frame: &mut Frame, rect: Rect) {
		let inner_rect = if rect.width >= 2 {
			rect.inner(Margin {
				horizontal: 1,
				vertical: 0,
			})
		} else {
			rect
		};

		frame.render_widget(
			Paragraph::new(self.get_info_text(&self.theme))
				.alignment(Alignment::Left),
			inner_rect,
		);
	}
}
