class_name MainScreen
extends Control

const SCENARIO_PATH: String = "res://game/data/scenarios/mist_bell/scenario.json"
const PRESET_PATH: String = "res://game/data/characters/mist_bell_scout.json"
const SAVE_SLOT: int = 0
const DICE_SPIN_INTERVAL_SECONDS: float = 0.07
const DICE_MIN_SPIN_SECONDS: float = 0.6


class DiceReveal:
	extends RefCounted

	var result: Judgment.Result
	var evidence: String
	var outcome: String

	func _init(
		resolved_result: Judgment.Result,
		judgment_evidence: String,
		judgment_outcome: String,
	) -> void:
		result = resolved_result
		evidence = judgment_evidence
		outcome = judgment_outcome

var _scenario: Scenario
var _state: GameState
var _save_manager: SaveManager
var _settings_store: ExternalSettingsStore
var _external_settings: Dictionary[String, Variant] = {}
var _backend: LLMBackend
var _machine: TurnMachine
var _log_entries: Array[Dictionary] = []
var _streaming_text: String = ""
var _streaming_is_narration: bool = false
var _busy: bool = false
var _load_failed_closed: bool = false
var _dice_tween: Tween
var _dice_animation_rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _dice_spin_timer: Timer
var _dice_reveal_timer: Timer
var _dice_spin_started_msec: int = 0
var _dice_spin_active: bool = false
var _pending_dice_reveal: DiceReveal
var _queued_dice_reveals: Array[DiceReveal] = []
var _queued_dice_spins: int = 0

var _log_label: RichTextLabel
var _title_label: Label
var _input_line: LineEdit
var _submit_button: Button
var _resume_button: Button
var _new_game_button: Button
var _skip_button: Button
var _status_label: Label
var _quest_label: Label
var _scene_label: Label
var _state_label: Label
var _dice_label: Label
var _hint_label: Label
var _external_indicator: ExternalConnectionIndicator
var _settings_dialog: ExternalSettingsDialog
var _fallback_dialog: ConfirmationDialog
var _retry_external_button: Button
var _last_submitted_input: String = ""
var _fallback_waiting: bool = false


func _ready() -> void:
	_dice_animation_rng.randomize()
	_build_interface()
	if not _load_content():
		return
	_log_entries.append(
		{
			"speaker": tr("導入"),
			"text": String(_scenario.data.get("intro_ja", "")),
			"color": "#9fb7d8",
		}
	)
	if _state.turn_count > 0:
		_log_entries.append(
			{
				"speaker": tr("システム"),
				"text": tr("保存済みの第%dターンから再開しました。") % _state.turn_count,
				"color": "#d5b878",
			}
		)
	_refresh_all()


func _build_interface() -> void:
	var background: ColorRect = ColorRect.new()
	background.color = Color("#111722")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var root_row: HBoxContainer = HBoxContainer.new()
	root_row.add_theme_constant_override("separation", 18)
	margin.add_child(root_row)

	var story_column: VBoxContainer = VBoxContainer.new()
	story_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	story_column.size_flags_stretch_ratio = 2.2
	story_column.add_theme_constant_override("separation", 10)
	root_row.add_child(story_column)

	_title_label = Label.new()
	_title_label.text = tr("AI TRPG")
	_title_label.add_theme_font_size_override("font_size", 28)
	_title_label.add_theme_color_override("font_color", Color("#e8d9ae"))
	story_column.add_child(_title_label)

	var connection_row: HBoxContainer = HBoxContainer.new()
	connection_row.add_theme_constant_override("separation", 10)
	story_column.add_child(connection_row)
	_external_indicator = ExternalConnectionIndicator.new()
	_external_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_row.add_child(_external_indicator)
	var settings_button: Button = Button.new()
	settings_button.text = tr("外部AI接続設定")
	settings_button.pressed.connect(_on_settings_pressed)
	connection_row.add_child(settings_button)

	_scene_label = Label.new()
	_scene_label.add_theme_font_size_override("font_size", 14)
	_scene_label.add_theme_color_override("font_color", Color("#90a5c2"))
	story_column.add_child(_scene_label)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.scroll_following = true
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_label.custom_minimum_size = Vector2(560, 360)
	_log_label.add_theme_font_size_override("normal_font_size", 17)
	story_column.add_child(_log_label)

	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_color_override("font_color", Color("#8fa7a0"))
	story_column.add_child(_hint_label)

	var input_row: HBoxContainer = HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 8)
	story_column.add_child(input_row)

	_input_line = LineEdit.new()
	_input_line.placeholder_text = tr("行動を日本語で入力…")
	_input_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_line.text_submitted.connect(_on_text_submitted)
	input_row.add_child(_input_line)

	_submit_button = Button.new()
	_submit_button.text = tr("行動する")
	_submit_button.pressed.connect(_on_submit_pressed)
	input_row.add_child(_submit_button)

	_skip_button = Button.new()
	_skip_button.text = tr("描写をスキップ")
	_skip_button.visible = false
	_skip_button.pressed.connect(_on_skip_pressed)
	input_row.add_child(_skip_button)

	_resume_button = Button.new()
	_resume_button.text = tr("前回の続きから描写する")
	_resume_button.visible = false
	_resume_button.pressed.connect(_on_resume_pressed)
	story_column.add_child(_resume_button)

	_retry_external_button = Button.new()
	_retry_external_button.text = tr("保持した入力で外部AIへ再接続")
	_retry_external_button.visible = false
	_retry_external_button.pressed.connect(_on_retry_external_pressed)
	story_column.add_child(_retry_external_button)

	_new_game_button = Button.new()
	_new_game_button.text = tr("新しく始める")
	_new_game_button.visible = false
	_new_game_button.pressed.connect(_on_new_game_pressed)
	story_column.add_child(_new_game_button)

	var side_panel: PanelContainer = PanelContainer.new()
	side_panel.custom_minimum_size = Vector2(310, 0)
	root_row.add_child(side_panel)

	var side_margin: MarginContainer = MarginContainer.new()
	side_margin.add_theme_constant_override("margin_left", 18)
	side_margin.add_theme_constant_override("margin_top", 18)
	side_margin.add_theme_constant_override("margin_right", 18)
	side_margin.add_theme_constant_override("margin_bottom", 18)
	side_panel.add_child(side_margin)

	var side_column: VBoxContainer = VBoxContainer.new()
	side_column.add_theme_constant_override("separation", 14)
	side_margin.add_child(side_column)

	_add_section_heading(side_column, tr("キャラクター"))
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_column.add_child(_status_label)

	_add_separator(side_column)
	_add_section_heading(side_column, tr("現在のクエスト"))
	_quest_label = Label.new()
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest_label.add_theme_font_size_override("font_size", 17)
	_quest_label.add_theme_color_override("font_color", Color("#e8d9ae"))
	side_column.add_child(_quest_label)

	_add_separator(side_column)
	_add_section_heading(side_column, tr("ダイス"))
	_dice_label = Label.new()
	_dice_label.text = tr("待機中")
	_dice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dice_label.add_theme_font_size_override("font_size", 22)
	_dice_label.add_theme_color_override("font_color", Color("#d5b878"))
	side_column.add_child(_dice_label)

	_dice_spin_timer = Timer.new()
	_dice_spin_timer.wait_time = DICE_SPIN_INTERVAL_SECONDS
	_dice_spin_timer.timeout.connect(_on_dice_spin_tick)
	add_child(_dice_spin_timer)
	_dice_reveal_timer = Timer.new()
	_dice_reveal_timer.one_shot = true
	_dice_reveal_timer.timeout.connect(_reveal_pending_dice_result)
	add_child(_dice_reveal_timer)

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side_column.add_child(spacer)

	_state_label = Label.new()
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_state_label.add_theme_color_override("font_color", Color("#79899e"))
	side_column.add_child(_state_label)

	_settings_store = ExternalSettingsStore.new()
	_settings_dialog = ExternalSettingsDialog.new(_settings_store)
	_settings_dialog.settings_saved.connect(_on_external_settings_saved)
	add_child(_settings_dialog)
	_fallback_dialog = ConfirmationDialog.new()
	_fallback_dialog.title = tr("外部AIへの接続に失敗しました")
	_fallback_dialog.dialog_text = tr(
		"3回の再試行後も接続できませんでした。同梱モデルへ一時的に切り替えますか？"
	)
	_fallback_dialog.ok_button_text = tr("同梱モデルへ切り替える")
	_fallback_dialog.cancel_button_text = tr("入力を保持して待機する")
	_fallback_dialog.confirmed.connect(_on_fallback_accepted)
	_fallback_dialog.canceled.connect(_on_fallback_declined)
	add_child(_fallback_dialog)


func _add_section_heading(parent: VBoxContainer, text: String) -> void:
	var heading: Label = Label.new()
	heading.text = text
	heading.add_theme_font_size_override("font_size", 14)
	heading.add_theme_color_override("font_color", Color("#90a5c2"))
	parent.add_child(heading)


func _add_separator(parent: VBoxContainer) -> void:
	var separator: HSeparator = HSeparator.new()
	parent.add_child(separator)


func _load_content() -> bool:
	var scenario_result: Scenario.LoadResult = Scenario.load_file(SCENARIO_PATH)
	if not scenario_result.is_success():
		_show_startup_error(
			tr("シナリオを読み込めませんでした: %s") % " / ".join(scenario_result.errors)
		)
		return false
	_scenario = scenario_result.scenario
	_title_label.text = String(_scenario.data.get("title", tr("AI TRPG")))
	_save_manager = SaveManager.new()
	var settings_result: ExternalSettingsStore.LoadResult = _settings_store.load_settings()
	_external_settings = settings_result.settings
	if not settings_result.is_success():
		_append_log_entry(
			tr("外部接続設定"),
			tr("外部接続設定を読み込めないため、完全オフラインで起動しました。"),
			"#d5b878",
		)
		_external_settings = _settings_store.default_settings()
	_external_indicator.apply_settings(_external_settings)
	_state = _load_saved_state()
	if _state == null:
		if _load_failed_closed:
			return false
		_state = _create_fresh_state()
	if _state == null:
		return false
	_install_machine()
	return true


func _install_machine() -> void:
	_backend = ExternalBackendFactory.create_for_state(_external_settings, _state)
	_backend.fallback_switch_proposed.connect(_on_fallback_proposed)
	_backend.fallback_mode_changed.connect(_on_fallback_mode_changed)
	_backend.constrained_output_support_changed.connect(
		_on_constrained_output_support_changed
	)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	_machine = TurnMachine.new(
		_backend,
		_state,
		_scenario,
		_save_manager,
		SAVE_SLOT,
		rng,
	)
	_connect_machine()


func _load_saved_state() -> GameState:
	var save_files_existed: bool = _slot_has_save_files()
	var save_result: SaveManager.LoadResult = _save_manager.load(SAVE_SLOT)
	if not save_result.is_success():
		if save_files_existed:
			_load_failed_closed = true
			_show_startup_error(
				tr("保存済みデータを読み込めませんでした。新規ゲームで上書きせず停止します: %s")
				% " / ".join(save_result.errors)
			)
		return null
	for warning: String in save_result.warnings:
		_append_log_entry(tr("セーブ通知"), warning, "#d5b878")
	if save_result.used_fallback:
		_append_log_entry(
			tr("セーブ通知"),
			tr("破損を検出したため、バックアップから復元しました。"),
			"#d5b878",
		)
	if save_result.promoted_temporary:
		_append_log_entry(
			tr("セーブ通知"),
			tr("未完了だった一時セーブを正式なセーブへ復元しました。"),
			"#d5b878",
		)
	var state_result: GameState.LoadResult = GameState.deserialize(save_result.data)
	if not state_result.is_success() or state_result.state == null:
		_load_failed_closed = true
		_show_startup_error(
			tr("セーブデータを復元できませんでした: %s") % " / ".join(state_result.errors)
		)
		return null
	if state_result.state.scenario_id != String(_scenario.data.get("id", "")):
		_load_failed_closed = true
		_show_startup_error(
			tr("セーブデータのシナリオが現在のシナリオと一致しません。")
		)
		return null
	return state_result.state


func _create_fresh_state() -> GameState:
	var preset_text: String = _read_text(PRESET_PATH)
	if preset_text.is_empty():
		_show_startup_error(tr("プリセットキャラクターを読み込めませんでした。"))
		return null
	var character_result: CharacterSheet.LoadResult = CharacterSheet.load(preset_text)
	if not character_result.is_success():
		_show_startup_error(
			tr("プリセットキャラクターが不正です: %s") % " / ".join(character_result.errors)
		)
		return null
	var scenes_value: Variant = _scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY or scenes_value.is_empty():
		_show_startup_error(tr("シナリオに開始シーンがありません。"))
		return null
	var scenes: Array = scenes_value
	var first_scene_value: Variant = scenes[0]
	if typeof(first_scene_value) != TYPE_DICTIONARY:
		_show_startup_error(tr("開始シーンのデータが不正です。"))
		return null
	var first_scene: Dictionary = first_scene_value
	var state: GameState = GameState.new()
	state.character = character_result.sheet
	state.scenario_id = String(_scenario.data.get("id", ""))
	state.scene_id = String(first_scene.get("id", ""))
	return state


func _connect_machine() -> void:
	_machine.state_changed.connect(_on_state_changed)
	_machine.display_reset_requested.connect(_on_display_reset_requested)
	_machine.display_text_appended.connect(_on_display_text_appended)
	_machine.narration_started.connect(_on_narration_started)
	_machine.narration_finished.connect(_on_narration_finished)
	_machine.judgment_resolved.connect(_on_judgment_resolved, CONNECT_DEFERRED)
	_machine.scenario_completed.connect(_on_scenario_completed)
	_machine.turn_failed.connect(_on_turn_failed)


func _on_submit_pressed() -> void:
	await _submit_current_input()


func _on_text_submitted(_submitted_text: String) -> void:
	await _submit_current_input()


func _submit_current_input() -> void:
	if (
		_busy
		or _machine == null
		or _machine.current_state != TurnMachine.State.IDLE
	):
		return
	var player_input: String = _input_line.text.strip_edges()
	if player_input.is_empty():
		return
	_last_submitted_input = player_input
	_input_line.clear()
	_log_entries.append(
		{"speaker": tr("あなた"), "text": player_input, "color": "#8fc6b2"}
	)
	_render_log()
	_set_input_enabled(false)
	await _machine.submit_input(player_input, _current_goal())
	_last_submitted_input = ""
	if not _fallback_waiting:
		_input_line.clear()
	_set_input_enabled(true)
	_refresh_all()


func _on_resume_pressed() -> void:
	if _busy or _machine == null:
		return
	_set_input_enabled(false)
	await _machine.resume_pending_narration()
	_set_input_enabled(true)
	_refresh_all()


func _on_new_game_pressed() -> void:
	if _busy or _save_manager == null or _scenario == null:
		return
	var fresh_state: GameState = _create_fresh_state()
	if fresh_state == null:
		return
	_set_input_enabled(false)
	var save_result: SaveManager.SaveResult = _save_manager.save(
		SAVE_SLOT,
		fresh_state.serialize(),
	)
	if not save_result.is_success():
		_show_startup_error(
			tr("新規ゲームを保存できませんでした: %s") % " / ".join(save_result.errors)
		)
		return
	_state = fresh_state
	_install_machine()
	_log_entries.clear()
	_streaming_text = ""
	_streaming_is_narration = false
	_append_log_entry(
		tr("導入"),
		String(_scenario.data.get("intro_ja", "")),
		"#9fb7d8",
	)
	_append_log_entry(
		tr("システム"),
		tr("新しいゲームを開始しました。"),
		"#d5b878",
	)
	_reset_dice_display()
	_set_input_enabled(true)
	_refresh_all()


func _on_skip_pressed() -> void:
	if _machine != null:
		_machine.skip_narration()


func _on_state_changed(_previous: int, current: int) -> void:
	_state_label.text = tr("状態: %s") % _localized_state_name(current)
	_skip_button.visible = current == TurnMachine.State.NARRATING
	if current == TurnMachine.State.ROLLING:
		_request_dice_spin()
	if current == TurnMachine.State.IDLE and not _streaming_text.is_empty():
		_log_entries.append(
			{
				"speaker": tr("システム"),
				"text": _streaming_text,
				"color": "#d5b878",
			}
		)
		_streaming_text = ""
		_streaming_is_narration = false
		_render_log()
	_refresh_status_and_quest()


func _on_display_reset_requested() -> void:
	_streaming_text = ""
	_render_log()


func _on_display_text_appended(text: String) -> void:
	_streaming_text += text
	_render_log()


func _on_narration_started(_resumed: bool) -> void:
	_streaming_is_narration = true


func _on_narration_finished(text: String) -> void:
	if not text.is_empty():
		_log_entries.append(
			{"speaker": tr("GM"), "text": text, "color": "#c7b7df"}
		)
	_streaming_text = ""
	_streaming_is_narration = false
	_render_log()


func _request_dice_spin() -> void:
	if _dice_spin_active or _is_dice_pulse_running():
		_queued_dice_spins += 1
		return
	_begin_dice_spin()


func _begin_dice_spin() -> void:
	if _dice_tween != null and _dice_tween.is_valid():
		_dice_tween.kill()
	_dice_tween = null
	_dice_label.scale = Vector2.ONE
	_dice_label.add_theme_color_override("font_color", Color("#f2cf77"))
	_dice_spin_started_msec = Time.get_ticks_msec()
	_dice_spin_active = true
	_update_dice_spin_digits()
	_dice_spin_timer.start()


func _on_dice_spin_tick() -> void:
	if not _dice_spin_active:
		return
	_update_dice_spin_digits()


func _update_dice_spin_digits() -> void:
	var first_die: int = _dice_animation_rng.randi_range(1, 6)
	var second_die: int = _dice_animation_rng.randi_range(1, 6)
	_dice_label.text = tr("%d・%d") % [first_die, second_die]


func _schedule_dice_reveal() -> void:
	if not _dice_spin_active or _pending_dice_reveal == null:
		return
	var elapsed_seconds: float = (
		float(Time.get_ticks_msec() - _dice_spin_started_msec) / 1000.0
	)
	var remaining_seconds: float = maxf(
		DICE_MIN_SPIN_SECONDS - elapsed_seconds,
		0.0,
	)
	if is_zero_approx(remaining_seconds):
		_reveal_pending_dice_result()
		return
	_dice_reveal_timer.start(remaining_seconds)


func _reveal_pending_dice_result() -> void:
	if not _dice_spin_active or _pending_dice_reveal == null:
		return
	_dice_spin_timer.stop()
	_dice_reveal_timer.stop()
	var reveal: DiceReveal = _pending_dice_reveal
	_pending_dice_reveal = null
	_dice_spin_active = false
	_dice_spin_started_msec = 0
	_dice_label.text = tr("出目 %s → %s") % [
		str(reveal.result.dice),
		_tier_label(reveal.result.tier),
	]
	_dice_label.add_theme_color_override("font_color", Color("#f2cf77"))
	_log_entries.append(
		{"speaker": tr("判定"), "text": reveal.evidence, "color": "#f2cf77"}
	)
	if not reveal.outcome.is_empty():
		_log_entries.append(
			{"speaker": tr("結果"), "text": reveal.outcome, "color": "#d5b878"}
		)
	_dice_label.scale = Vector2.ONE
	_dice_tween = create_tween()
	_dice_tween.tween_property(_dice_label, "scale", Vector2(1.12, 1.12), 0.12)
	_dice_tween.tween_property(_dice_label, "scale", Vector2.ONE, 0.18)
	_dice_tween.finished.connect(_on_dice_pulse_finished)
	_render_log()


func _on_dice_pulse_finished() -> void:
	_dice_tween = null
	_start_next_queued_dice_spin()


func _start_next_queued_dice_spin() -> void:
	if _dice_spin_active or _is_dice_pulse_running():
		return
	if _queued_dice_spins <= 0 and _queued_dice_reveals.is_empty():
		return
	if _queued_dice_spins > 0:
		_queued_dice_spins -= 1
	_begin_dice_spin()
	if not _queued_dice_reveals.is_empty():
		_pending_dice_reveal = _queued_dice_reveals.pop_front()
		_schedule_dice_reveal()


func _is_dice_pulse_running() -> bool:
	return (
		_dice_tween != null
		and _dice_tween.is_valid()
		and _dice_tween.is_running()
	)


func _cancel_dice_animation() -> void:
	if _dice_spin_timer != null:
		_dice_spin_timer.stop()
	if _dice_reveal_timer != null:
		_dice_reveal_timer.stop()
	_dice_spin_active = false
	_dice_spin_started_msec = 0
	_pending_dice_reveal = null
	_queued_dice_reveals.clear()
	_queued_dice_spins = 0
	if _dice_tween != null and _dice_tween.is_valid():
		_dice_tween.kill()
	_dice_tween = null
	if _dice_label != null:
		_dice_label.scale = Vector2.ONE


func _reset_dice_display() -> void:
	_cancel_dice_animation()
	if _dice_label == null:
		return
	_dice_label.text = tr("待機中")
	_dice_label.add_theme_color_override("font_color", Color("#d5b878"))


func _on_judgment_resolved(result: Judgment.Result) -> void:
	var outcome: String = _judgment_outcome()
	var reveal: DiceReveal = DiceReveal.new(
		result,
		_judgment_evidence(result),
		outcome,
	)
	if _dice_spin_active and _pending_dice_reveal == null:
		_pending_dice_reveal = reveal
		_schedule_dice_reveal()
		return
	_queued_dice_reveals.append(reveal)
	_queued_dice_spins = maxi(_queued_dice_spins, _queued_dice_reveals.size())
	if not _dice_spin_active and not _is_dice_pulse_running():
		_start_next_queued_dice_spin()


func _on_scenario_completed(xp: int, money: int) -> void:
	_log_entries.append(
		{
			"speaker": tr("クリア"),
			"text": tr("報酬を獲得しました: XP +%d / 所持金 +%d") % [xp, money],
			"color": "#8fd4a7",
		}
	)
	_render_log()


func _on_turn_failed(message: String) -> void:
	_reset_dice_display()
	_log_entries.append(
		{"speaker": tr("エラー"), "text": message, "color": "#e58b8b"}
	)
	_render_log()


func _on_settings_pressed() -> void:
	if _busy and (_backend == null or not _backend.has_pending_fallback()):
		return
	_settings_dialog.popup_centered()


func _on_external_settings_saved(settings: Dictionary) -> void:
	_external_settings = settings.duplicate(true)
	_fallback_waiting = false
	_retry_external_button.visible = false
	_external_indicator.apply_settings(_external_settings)
	if _state != null:
		if _machine != null and _machine.current_state != TurnMachine.State.IDLE:
			_apply_settings_when_machine_idle.call_deferred(_machine)
		else:
			_install_machine()
	_append_log_entry(
		tr("外部接続設定"),
		tr("AI接続設定を反映しました。"),
		"#d5b878",
	)


func _on_fallback_proposed(_error: LLMBackend.LLMError) -> void:
	_fallback_waiting = true
	if not _last_submitted_input.is_empty():
		_input_line.text = _last_submitted_input
	_fallback_dialog.popup_centered()


func _on_fallback_accepted() -> void:
	if _backend != null:
		_backend.respond_to_fallback(true)
	_fallback_waiting = false
	_input_line.clear()
	_retry_external_button.visible = false


func _on_fallback_declined() -> void:
	if _backend != null:
		_backend.respond_to_fallback(false)
	_retry_external_button.visible = true


func _on_retry_external_pressed() -> void:
	if _backend != null:
		_backend.retry_pending_request()
		_external_indicator.apply_settings(_external_settings)
	_fallback_waiting = false
	_set_input_enabled(true)
	_retry_external_button.visible = false


func _on_fallback_mode_changed(using_fallback: bool) -> void:
	_external_indicator.apply_fallback_state(using_fallback, _external_settings)


func _on_constrained_output_support_changed(supported: bool) -> void:
	if supported:
		return
	_settings_dialog.show_constrained_output_warning()
	_append_log_entry(
		tr("外部接続設定"),
		tr("送信先は構造化出力に非対応です。分類が不安定になる可能性があります。"),
		"#d5b878",
	)


func _apply_settings_when_machine_idle(previous_machine: TurnMachine) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	while (
		_machine == previous_machine
		and previous_machine.current_state != TurnMachine.State.IDLE
		and tree != null
	):
		await tree.process_frame
	if _machine == previous_machine:
		_install_machine()


func _refresh_all() -> void:
	_render_log()
	_refresh_status_and_quest()
	var has_pending: bool = typeof(_state.pending_narration) == TYPE_DICTIONARY
	var cleared: bool = bool(_state.flags.get("scenario_cleared", false))
	_resume_button.visible = has_pending
	_new_game_button.visible = cleared
	_set_input_enabled(not has_pending)


func _refresh_status_and_quest() -> void:
	if _state == null:
		return
	var character: CharacterSheet = _state.character
	_status_label.text = (
		tr("%s\nHP %d / %d\nXP %d　所持金 %d\n\n能力値\n筋力 %+d　敏捷 %+d　体力 %+d\n知力 %+d　判断 %+d　魅力 %+d")
		% [
			character.name,
			int(character.hp.get("current", 0)),
			int(character.hp.get("max", 0)),
			character.xp,
			character.money,
			int(character.abilities.get("STR", 0)),
			int(character.abilities.get("DEX", 0)),
			int(character.abilities.get("CON", 0)),
			int(character.abilities.get("INT", 0)),
			int(character.abilities.get("WIS", 0)),
			int(character.abilities.get("CHA", 0)),
		]
	)
	var scene: Dictionary = _current_scene()
	_scene_label.text = tr("第%dターン") % (_state.turn_count + 1)
	if bool(_state.flags.get("scenario_cleared", false)):
		_quest_label.text = tr("シナリオクリア！\n霧鐘に夜明けが戻った")
	else:
		_quest_label.text = String(scene.get("goal_ja", tr("目標を確認できません。")))
	_hint_label.text = _input_hint()


func _render_log() -> void:
	var output: String = ""
	for entry: Dictionary in _log_entries:
		output += "[color=%s][b]%s[/b][/color]\n%s\n\n" % [
			String(entry.get("color", "#ffffff")),
			_escape_bbcode(String(entry.get("speaker", ""))),
			_escape_bbcode(String(entry.get("text", ""))),
		]
	if not _streaming_text.is_empty():
		var streaming_speaker: String = tr("GM") if _streaming_is_narration else tr("システム")
		output += "[color=#c7b7df][b]%s[/b][/color]\n%s[color=#79899e]▌[/color]" % [
			_escape_bbcode(streaming_speaker),
			_escape_bbcode(_streaming_text),
		]
	_log_label.text = output
	call_deferred("_scroll_log_to_bottom")


func _scroll_log_to_bottom() -> void:
	_log_label.scroll_to_line(maxi(_log_label.get_line_count() - 1, 0))


func _set_input_enabled(enabled: bool) -> void:
	_busy = not enabled
	var cleared: bool = (
		_state != null and bool(_state.flags.get("scenario_cleared", false))
	)
	_input_line.editable = enabled and not cleared
	_submit_button.disabled = not enabled or cleared
	_new_game_button.disabled = not enabled
	if _input_line.editable:
		_input_line.grab_focus()


func _current_scene() -> Dictionary:
	if _scenario == null or _state == null:
		return {}
	var scenes_value: Variant = _scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY:
		return {}
	var scenes: Array = scenes_value
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) == _state.scene_id:
			return scene
	return {}


func _current_goal() -> String:
	return String(_current_scene().get("goal_ja", ""))


func _input_hint() -> String:
	match _state.scene_id:
		"fog_gate":
			return tr("入力例: 霧門の刻印を調べる")
		"sunken_archive":
			return tr("入力例: 書架を読み、月鍵を探す")
		"observatory":
			return tr("入力例: 星見鏡の歯車を調整する")
		"dawn_sanctum":
			return tr("入力例: 霧の残響に帰る場所を語りかける")
		"rescue":
			return tr("入力例: 手当てを受けて聖堂へ戻る")
		_:
			return tr("行動を入力してください。")


func _judgment_evidence(result: Judgment.Result) -> String:
	var ability_id: String = ""
	var roll_mode: String = tr("通常")
	if _machine.last_judgment_request != null:
		ability_id = _ability_id(_machine.last_judgment_request.ability)
		match _machine.last_judgment_request.roll_mode:
			Types.RollMode.ADVANTAGE:
				roll_mode = tr("有利")
			Types.RollMode.DISADVANTAGE:
				roll_mode = tr("不利")
	var applied_skill: String = tr("なし（能力値のみ採用）")
	if not result.applied_tag.is_empty():
		applied_skill = tr("%s（+%d、完全一致のため採用）") % [
			result.applied_tag,
			result.skill_bonus,
		]
	var rejected: String = tr("なし")
	if not result.rejected_tags.is_empty():
		rejected = tr("%s（不採用: 所持タグとの完全一致なし、またはボーナス重複）") % str(
			result.rejected_tags
		)
	return (
		tr("能力値: %s %+d\nスキル: %s\n不採用候補: %s\n状況修正: %+d / ロール: %s\n出目: %s / 採用: %s / 合計: %d\n結果: %s")
		% [
			ability_id,
			result.ability_mod,
			applied_skill,
			rejected,
			result.situation_mod,
			roll_mode,
			str(result.dice),
			str(result.kept),
			result.total,
			_tier_label(result.tier),
		]
	)


func _judgment_outcome() -> String:
	if _machine.last_check_resolution != null:
		var check_resolution: CheckResolver.CheckResolution = _machine.last_check_resolution
		var parts: Array[String] = []
		var trigger_hint: String = _check_trigger_hint(check_resolution.check_id)
		if not trigger_hint.is_empty():
			parts.append(tr("◆ %s") % trigger_hint)
		var effects: String = _resolution_effects_text(
			check_resolution.applied_effects,
			check_resolution.no_state_change,
		)
		if not effects.is_empty():
			parts.append(effects)
		return "\n".join(parts)
	if _machine.last_action_resolution != null:
		var action_resolution: ActionResolver.ActionResolution = (
			_machine.last_action_resolution
		)
		return _resolution_effects_text(
			action_resolution.applied_effects,
			action_resolution.no_state_change,
		)
	return ""


func _resolution_effects_text(
	applied_effects: Array[String],
	no_state_change: bool,
) -> String:
	var lines: Array[String] = []
	for effect: String in applied_effects:
		lines.append(effect)
	if lines.is_empty() and no_state_change:
		lines.append(tr("状態変化なし"))
	return "\n".join(lines)


func _check_trigger_hint(check_id: String) -> String:
	if _scenario == null or check_id.is_empty():
		return ""
	var scenes_value: Variant = _scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY:
		return ""
	var scenes: Array = scenes_value
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		var checks_value: Variant = scene.get("checks", [])
		if typeof(checks_value) != TYPE_ARRAY:
			continue
		var checks: Array = checks_value
		for check_value: Variant in checks:
			if typeof(check_value) != TYPE_DICTIONARY:
				continue
			var check: Dictionary = check_value
			if String(check.get("id", "")) == check_id:
				return String(check.get("trigger_hint", ""))
	return ""


func _ability_id(ability: Types.Ability) -> String:
	match ability:
		Types.Ability.STR:
			return "STR"
		Types.Ability.DEX:
			return "DEX"
		Types.Ability.CON:
			return "CON"
		Types.Ability.INT:
			return "INT"
		Types.Ability.WIS:
			return "WIS"
		Types.Ability.CHA:
			return "CHA"
		_:
			return ""


func _tier_label(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.FUMBLE:
			return tr("ファンブル")
		Types.ResultTier.FAILURE:
			return tr("失敗")
		Types.ResultTier.PARTIAL:
			return tr("部分成功")
		Types.ResultTier.SUCCESS:
			return tr("成功")
		Types.ResultTier.CRITICAL:
			return tr("クリティカル")
		_:
			return tr("不明")


func _localized_state_name(state_value: int) -> String:
	match state_value:
		TurnMachine.State.IDLE:
			return tr("入力待ち")
		TurnMachine.State.INPUT_RECEIVED, TurnMachine.State.INPUT_FILTERING:
			return tr("入力確認中")
		TurnMachine.State.CLASSIFYING, TurnMachine.State.VALIDATING:
			return tr("行動を解釈中")
		TurnMachine.State.ROLLING:
			return tr("判定中")
		TurnMachine.State.RESOLVING_ACTION, TurnMachine.State.COMMITTING:
			return tr("結果を保存中")
		TurnMachine.State.NARRATING:
			return tr("描写を生成中")
		TurnMachine.State.FINALIZING:
			return tr("ターンを確定中")
		_:
			return tr("不明")


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _slot_has_save_files() -> bool:
	var slot_path: String = _save_manager.root_path.path_join("slot_%d" % SAVE_SLOT)
	for file_name: String in [
		"save.json",
		"save.tmp.json",
		"save.bak1.json",
		"save.bak2.json",
	]:
		if FileAccess.file_exists(slot_path.path_join(file_name)):
			return true
	return false


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


func _append_log_entry(speaker: String, text: String, color: String) -> void:
	_log_entries.append(
		{"speaker": speaker, "text": text, "color": color}
	)
	_render_log()


func _show_startup_error(message: String) -> void:
	_reset_dice_display()
	_append_log_entry(tr("起動エラー"), message, "#e58b8b")
	_set_input_enabled(false)
