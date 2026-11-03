use std::time::Instant;

use anyhow::Result;
use asyncgit::{sync::utils::repo_work_dir, AsyncGitNotification};
use crossbeam_channel::{never, tick, unbounded, Receiver};
use scopetime::scope_time;

#[cfg(test)]
use crossterm::event::{KeyCode, KeyModifiers};

use crate::{
	app::{App, QuitState},
	args::CliArgs,
	draw,
	input::{Input, InputEvent, InputState},
	keys::KeyConfig,
	select_event,
	spinner::Spinner,
	ui::style::Theme,
	watcher::RepoWatcher,
	AsyncAppNotification, AsyncNotification, QueueEvent, Updater,
	SPINNER_INTERVAL, TICK_INTERVAL,
};

pub struct Gitui {
	app: crate::app::App,
	rx_input: Receiver<InputEvent>,
	rx_git: Receiver<AsyncGitNotification>,
	rx_app: Receiver<AsyncAppNotification>,
	rx_ticker: Receiver<Instant>,
	rx_watcher: Receiver<()>,
}

impl Gitui {
	pub(crate) fn new(
		cliargs: CliArgs,
		theme: Theme,
		key_config: &KeyConfig,
		updater: Updater,
	) -> Result<Self, anyhow::Error> {
		let (tx_git, rx_git) = unbounded();
		let (tx_app, rx_app) = unbounded();

		let input = Input::new();

		let (rx_ticker, rx_watcher) = match updater {
			Updater::NotifyWatcher => {
				let repo_watcher = RepoWatcher::new(
					repo_work_dir(&cliargs.repo_path)?.as_str(),
				);

				(never(), repo_watcher.receiver())
			}
			Updater::Ticker => (tick(TICK_INTERVAL), never()),
		};

		let app = App::new(
			cliargs,
			tx_git,
			tx_app,
			input.clone(),
			theme,
			key_config.clone(),
		)?;

		Ok(Self {
			app,
			rx_input: input.receiver(),
			rx_git,
			rx_app,
			rx_ticker,
			rx_watcher,
		})
	}

	pub(crate) fn run_main_loop<B: ratatui::backend::Backend>(
		&mut self,
		terminal: &mut ratatui::Terminal<B>,
	) -> Result<QuitState, anyhow::Error>
	where
		<B as ratatui::backend::Backend>::Error:
			'static + Send + Sync,
	{
		let spinner_ticker = tick(SPINNER_INTERVAL);
		let mut spinner = Spinner::default();
		let mut first_update = true;

		self.app.update()?;

		loop {
			let event = if first_update {
				first_update = false;
				QueueEvent::Notify
			} else {
				select_event(
					&self.rx_input,
					&self.rx_git,
					&self.rx_app,
					&self.rx_ticker,
					&self.rx_watcher,
					&spinner_ticker,
				)?
			};

			{
				if matches!(event, QueueEvent::SpinnerUpdate) {
					spinner.update();
					spinner.draw(terminal)?;
					continue;
				}

				scope_time!("loop");

				match event {
					QueueEvent::InputEvent(ev) => {
						if matches!(
							ev,
							InputEvent::State(InputState::Polling)
						) {
							//Note: external ed closed, we need to re-hide cursor
							terminal.hide_cursor()?;
						}
						self.app.event(ev)?;
					}
					QueueEvent::Tick | QueueEvent::Notify => {
						self.app.update()?;
					}
					QueueEvent::AsyncEvent(ev) => {
						if !matches!(
							ev,
							AsyncNotification::Git(
								AsyncGitNotification::FinishUnchanged
							)
						) {
							self.app.update_async(ev)?;
						}
					}
					QueueEvent::SpinnerUpdate => unreachable!(),
				}

				self.draw(terminal)?;

				spinner.set_state(self.app.any_work_pending());
				spinner.draw(terminal)?;

				if self.app.is_quit() {
					break;
				}
			}
		}

		Ok(self.app.quit_state())
	}

	fn draw<B: ratatui::backend::Backend>(
		&self,
		terminal: &mut ratatui::Terminal<B>,
	) -> Result<(), B::Error> {
		draw(terminal, &self.app)
	}

	#[cfg(test)]
	fn update_async(&mut self, event: crate::AsyncNotification) {
		self.app.update_async(event).unwrap();
	}

	#[cfg(test)]
	fn input_event(
		&mut self,
		code: KeyCode,
		modifiers: KeyModifiers,
	) {
		let event = crossterm::event::KeyEvent::new(code, modifiers);
		self.app
			.event(crate::input::InputEvent::Input(
				crossterm::event::Event::Key(event),
			))
			.unwrap();
	}

	#[cfg(test)]
	fn wait_for_async_git_notification(
		&self,
		expected: AsyncGitNotification,
	) {
		loop {
			let actual = self
				.rx_git
				.recv_timeout(std::time::Duration::from_millis(100))
				.unwrap();

			if actual == expected {
				break;
			}
		}
	}

	#[cfg(test)]
	fn update(&mut self) {
		self.app.update().unwrap();
	}
}

#[cfg(test)]
mod tests {
	use std::path::PathBuf;

	use asyncgit::{sync::RepoPath, AsyncGitNotification};
	use crossterm::event::{KeyCode, KeyModifiers};
	use git2_testing::repo_init_suffix;
	use insta::assert_snapshot;
	use ratatui::{backend::TestBackend, Terminal};

	use crate::{
		args::CliArgs, gitui::Gitui, keys::KeyConfig,
		ui::style::Theme, AsyncNotification, Updater,
	};

	// Macro adapted from: https://insta.rs/docs/cmd/
	macro_rules! apply_common_filters {
		{} => {
			let mut settings = insta::Settings::clone_current();
			// Windows and MacOS
			// We don't match on the full path, but on the suffix we pass to `repo_init_suffix` below.
			settings.add_filter(r" *\[…\]\S+-insta/?", "[TEMP_FILE]");
			// Linux Temp Folder
			settings.add_filter(r" */tmp/\.tmp\S+-insta/", "[TEMP_FILE]");
			// Commit ids that follow a vertical bar
			settings.add_filter(r"│[a-z0-9]{7} ", "│[AAAAA] ");
			let _bound = settings.bind_to_scope();
		}
	}

	#[test]
	fn gitui_starts() {
		apply_common_filters!();

		let (temp_dir, _repo) = repo_init_suffix(Some("-insta"));
		let path: RepoPath = temp_dir.path().to_str().unwrap().into();
		let cliargs = CliArgs {
			theme: PathBuf::from("theme.ron"),
			select_file: None,
			repo_path: path,
			notify_watcher: false,
			key_bindings_path: None,
			key_symbols_path: None,
		};

		let theme = Theme::init(&PathBuf::new());
		let key_config = KeyConfig::default();

		let mut gitui =
			Gitui::new(cliargs, theme, &key_config, Updater::Ticker)
				.unwrap();

		let mut terminal =
			Terminal::new(TestBackend::new(90, 12)).unwrap();

		gitui.draw(&mut terminal).unwrap();

		assert_snapshot!("app_loading", terminal.backend());

		let event =
			AsyncNotification::Git(AsyncGitNotification::Status);
		gitui.update_async(event);

		gitui.draw(&mut terminal).unwrap();

		assert_snapshot!("app_loading_finished", terminal.backend());

		gitui.input_event(KeyCode::Char('2'), KeyModifiers::empty());
		gitui.input_event(
			key_config.keys.tab_log.code,
			key_config.keys.tab_log.modifiers,
		);

		gitui.wait_for_async_git_notification(
			AsyncGitNotification::Log,
		);

		gitui.update();

		gitui.draw(&mut terminal).unwrap();

		assert_snapshot!(
			"app_log_tab_showing_one_commit",
			terminal.backend()
		);
	}

	macro_rules! press {
		($gitui:expr, $key:expr) => {
			$gitui.input_event($key.code, $key.modifiers)
		};
	}

	/// drives the real key sequence: worktree list -> create popup ->
	/// replace suggested path -> confirm
	fn create_worktree_via_ui(
		gitui: &mut Gitui,
		key_config: &KeyConfig,
		path: &std::path::Path,
	) {
		let keys = &key_config.keys;
		press!(gitui, keys.create_branch);
		gitui.input_event(KeyCode::End, KeyModifiers::empty());
		for _ in 0..300 {
			gitui.input_event(
				KeyCode::Backspace,
				KeyModifiers::empty(),
			);
		}
		for c in path.to_str().unwrap().chars() {
			gitui
				.input_event(KeyCode::Char(c), KeyModifiers::empty());
		}
		press!(gitui, keys.enter);
	}

	#[test]
	fn gitui_worktree_flow() {
		use crate::app::QuitState;
		use asyncgit::sync::get_worktrees;

		let (temp_dir, _repo) = repo_init_suffix(Some("-wt"));
		let repo_path: RepoPath =
			temp_dir.path().to_str().unwrap().into();
		let cliargs = CliArgs {
			theme: PathBuf::from("theme.ron"),
			select_file: None,
			repo_path: repo_path.clone(),
			notify_watcher: false,
			key_bindings_path: None,
			key_symbols_path: None,
		};
		let key_config = KeyConfig::default();
		let keys = &key_config.keys;
		let mut gitui = Gitui::new(
			cliargs,
			Theme::init(&PathBuf::new()),
			&key_config,
			Updater::Ticker,
		)
		.unwrap();
		let mut terminal =
			Terminal::new(TestBackend::new(100, 30)).unwrap();
		gitui.draw(&mut terminal).unwrap();
		gitui.update_async(AsyncNotification::Git(
			AsyncGitNotification::Status,
		));

		let wt_parent = tempfile::TempDir::new().unwrap();
		let wt_path = wt_parent.path().join("ui-wt");

		// create
		press!(gitui, keys.view_worktrees);
		gitui.draw(&mut terminal).unwrap();
		create_worktree_via_ui(&mut gitui, &key_config, &wt_path);
		assert!(
			wt_path.join(".git").exists(),
			"worktree not created"
		);
		assert_eq!(get_worktrees(&repo_path).unwrap().len(), 2);
		gitui.draw(&mut terminal).unwrap();

		// delete is refused while the worktree has uncommitted work
		std::fs::write(wt_path.join("wip.txt"), "wip").unwrap();
		press!(gitui, keys.move_down);
		press!(gitui, keys.delete_branch);
		press!(gitui, keys.enter); // confirm
		assert!(wt_path.join("wip.txt").exists());
		assert_eq!(get_worktrees(&repo_path).unwrap().len(), 2);
		press!(gitui, keys.exit_popup); // close error message

		// clean worktree deletes fine
		std::fs::remove_file(wt_path.join("wip.txt")).unwrap();
		press!(gitui, keys.delete_branch);
		press!(gitui, keys.enter);
		assert!(!wt_path.exists());
		assert_eq!(get_worktrees(&repo_path).unwrap().len(), 1);

		// open: app asks to be restarted inside the worktree
		create_worktree_via_ui(&mut gitui, &key_config, &wt_path);
		gitui.draw(&mut terminal).unwrap();
		press!(gitui, keys.move_down);
		press!(gitui, keys.enter);
		match gitui.app.quit_state() {
			QuitState::OpenSubmodule(p) => assert_eq!(
				p.gitpath().canonicalize().unwrap(),
				wt_path.canonicalize().unwrap()
			),
			_ => panic!("expected OpenSubmodule quit state"),
		}
	}
}
