class_name TurnMachine
extends RefCounted

signal state_changed(previous: int, current: int)
signal display_text_appended(text: String)
signal display_reset_requested()
signal save_flushed(slot: int)
signal narration_started(resumed: bool)
signal narration_finished(text: String)
signal judgment_resolved(result: Judgment.Result)
signal turn_failed(message: String)


enum State {
	IDLE,
	INPUT_RECEIVED,
	INPUT_FILTERING,
	CLASSIFYING,
	VALIDATING,
	ROLLING,
	RESOLVING_ACTION,
	COMMITTING,
	NARRATING,
	FINALIZING,
}

const NARRATION_MAX_TOKENS: int = 400
const NARRATION_TEMPERATURE: float = 0.8
const DETERMINISTIC_ACTION_TYPES: Array[String] = ["move", "item", "talk"]

var current_state: State = State.IDLE
var state_history: Array[int] = [State.IDLE]
var display_buffer: String = ""
var display_history: Array[String] = []
var recent_logs: Array[String] = []
var rolling_summary: String = ""
var last_error: String = ""
var last_intent: IntentClassifier.Result = null
var last_judgment: Judgment.Result = null
var last_action_resolution: ActionResolver.ActionResolution = null
var last_check_resolution: CheckResolver.CheckResolution = null

var _backend: LLMBackend
var _state: GameState
var _scenario: Scenario
var _save_manager: SaveManager
var _slot: int
var _rng: RandomNumberGenerator
var _guardrails: Guardrails
var _intent_classifier: IntentClassifier
var _narrator: Narrator
var _summarizer: Summarizer
var _generation_active: bool = false
var _generation_owner: String = ""
var _narration_skip_requested: bool = false
var _narration_generation_in_progress: bool = false
var _narration_history_start_index: int = 0
var _pending_narration_saved: bool = false
var _current_player_input: String = ""


func _init(
	backend: LLMBackend,
	game_state: GameState,
	scenario: Scenario,
	save_manager: SaveManager,
	slot: int = 0,
	rng: RandomNumberGenerator = null,
) -> void:
	_backend = backend
	_state = game_state
	_scenario = scenario
	_save_manager = save_manager
	_slot = slot
	_rng = rng if rng != null else RandomNumberGenerator.new()
	rolling_summary = _state.rolling_summary
	recent_logs = _state.recent_logs.duplicate()

	assert(_backend != null, "TurnMachineにはLLMBackendの注入が必要です。")
	assert(_state != null, "TurnMachineにはGameStateの注入が必要です。")
	assert(_scenario != null, "TurnMachineにはScenarioの注入が必要です。")
	assert(_save_manager != null, "TurnMachineにはSaveManagerの注入が必要です。")

	# 同一LLMBackendへ接続した各AI部品は、並行待機すると同じsignalを奪い合う。
	# 本クラスは_generation_activeを唯一の生成ゲートとし、分類・描写・要約を
	# 必ず一つずつ直列実行することを不変条件とする。
	_guardrails = Guardrails.new(_backend)
	_intent_classifier = IntentClassifier.new(_backend)
	_narrator = Narrator.new(_backend)
	_summarizer = Summarizer.new(_backend)
	_guardrails.sentence_ready.connect(_on_guarded_sentence_ready)
	_guardrails.generation_discarded.connect(_on_guarded_generation_discarded)


func submit_input(player_input: String, scene_summary: String = "") -> bool:
	if current_state != State.IDLE or _generation_active:
		_fail_turn(tr("前のターンの処理が完了するまでお待ちください。"))
		return false
	if _state.pending_narration != null:
		_fail_turn(tr("前回の未描写結果が残っています。先に描写を再開してください。"))
		return false

	last_error = ""
	last_intent = null
	last_judgment = null
	last_action_resolution = null
	last_check_resolution = null
	_current_player_input = player_input
	_transition_to(State.INPUT_RECEIVED)
	_transition_to(State.INPUT_FILTERING)

	var input_result: Guardrails.InputResult = _guardrails.filter_input(player_input)
	if input_result.blocked:
		# Guardrails自身が返した定型文だけを表示する。分類器やバックエンドへは到達しない。
		display_buffer = ""
		display_reset_requested.emit()
		_publish_guarded_text(input_result.response)
		_transition_to(State.IDLE)
		return false

	_transition_to(State.CLASSIFYING)
	if not _begin_generation("intent"):
		_transition_to(State.IDLE)
		return false
	var resolved_scene_summary: String = scene_summary
	if resolved_scene_summary.is_empty():
		resolved_scene_summary = _current_scene_summary()
	var intent: IntentClassifier.Result = await _intent_classifier.classify(
		player_input,
		resolved_scene_summary,
		_state,
		_scenario,
	)
	_end_generation("intent")
	last_intent = intent
	_transition_to(State.VALIDATING)

	# IntentClassifierがコード検証と最大1回の再分類を担当する既存契約である。
	# ここでは検証済みResultだけを受け取り、実行不可なら状態を変更せず終了する。
	if not intent.executable:
		var confirmation: String = intent.confirmation_response
		if confirmation.is_empty():
			confirmation = tr("もう少し具体的に何をするか教えてください。")
		_publish_system_text(confirmation)
		_transition_to(State.IDLE)
		return false

	var confirmed_result: Dictionary[String, Variant] = {}
	if intent.needs_roll:
		_transition_to(State.ROLLING)
		var roll_request: Judgment.Request = _request_for_roll(intent)
		last_judgment = Judgment.resolve(roll_request, _state.character, _rng)
		judgment_resolved.emit(last_judgment)
		_transition_to(State.COMMITTING)
		if DETERMINISTIC_ACTION_TYPES.has(intent.action_type):
			# needs_rollの誤分類でも§7.1の状態確定を迂回させない。
			last_action_resolution = ActionResolver.resolve(
				intent.to_dict(),
				_state,
				_scenario,
			)
			confirmed_result = _confirmed_action_result(
				intent,
				last_action_resolution,
				last_judgment,
			)
		else:
			confirmed_result = _commit_rolled_action(intent, last_judgment)
	else:
		_transition_to(State.RESOLVING_ACTION)
		last_action_resolution = ActionResolver.resolve(
			intent.to_dict(),
			_state,
			_scenario,
		)
		_transition_to(State.COMMITTING)
		confirmed_result = _confirmed_action_result(intent, last_action_resolution)

	_state.turn_count += 1
	_state.pending_narration = _build_pending_narration(
		player_input,
		intent,
		confirmed_result,
	)
	_pending_narration_saved = false
	if not _save_state():
		# 効果はメモリ上で確定済みだが、保存未完了なので描写へは絶対に進めない（INV-6）。
		_transition_to(State.IDLE)
		return false
	_pending_narration_saved = true
	save_flushed.emit(_slot)

	# COMMITTINGの保存フラッシュが成功した後にだけNARRATINGへ入る。
	# 分類完了signalの配送も終えてから次の生成待機を開始し、接続順への依存を残さない。
	await _wait_for_backend_signal_dispatch()
	return await _run_pending_narration(false)


func resume_pending_narration() -> bool:
	if current_state != State.IDLE or _generation_active:
		_fail_turn(tr("前のターンの処理が完了するまでお待ちください。"))
		return false
	if typeof(_state.pending_narration) != TYPE_DICTIONARY:
		_fail_turn(tr("再開できる未描写結果がありません。"))
		return false
	var pending: Dictionary = _state.pending_narration
	_current_player_input = String(pending.get("player_input", ""))
	if not _pending_narration_saved:
		# 新規ロードか直前の保存失敗かを問わず、描写前に現在のpendingを再保存する。
		_transition_to(State.COMMITTING)
		if not _save_state():
			_transition_to(State.IDLE)
			return false
		_pending_narration_saved = true
		save_flushed.emit(_slot)
		await _wait_for_backend_signal_dispatch()
	return await _run_pending_narration(true)


func skip_narration() -> bool:
	if current_state != State.NARRATING:
		return false
	# BackendMockを含むLLMBackendのcancel()契約は完了signalを保証しない。
	# そのため生成待ちを孤立させず、以後の安全なセンテンスを表示せずに捨て、
	# 現在まで表示確定した文だけを保持して生成完了後にFINALIZINGへ進む。
	# ガードレール再生成は要求しないため、内容の振り直しにもならない（INV-6）。
	# PR-13でcancel時にも終端signalを必須とするまではbackend.cancel()を呼ばない。
	_narration_skip_requested = true
	_transition_to(State.FINALIZING)
	return true


func get_game_state() -> GameState:
	return _state


static func state_name(value: int) -> String:
	match value:
		State.IDLE:
			return "IDLE"
		State.INPUT_RECEIVED:
			return "INPUT_RECEIVED"
		State.INPUT_FILTERING:
			return "INPUT_FILTERING"
		State.CLASSIFYING:
			return "CLASSIFYING"
		State.VALIDATING:
			return "VALIDATING"
		State.ROLLING:
			return "ROLLING"
		State.RESOLVING_ACTION:
			return "RESOLVING_ACTION"
		State.COMMITTING:
			return "COMMITTING"
		State.NARRATING:
			return "NARRATING"
		State.FINALIZING:
			return "FINALIZING"
		_:
			return "UNKNOWN"


func _commit_rolled_action(
	intent: IntentClassifier.Result,
	judgment_result: Judgment.Result,
) -> Dictionary[String, Variant]:
	if intent.action_type == "check":
		last_check_resolution = CheckResolver.resolve(
			intent.target,
			judgment_result,
			_state,
			_scenario,
			_rng,
		)
		return _confirmed_check_result(intent, judgment_result, last_check_resolution)

	# combat.gdはPR-16の責務である。PR-12では判定根拠を確定・保存し、
	# check:<id>以外の宣言的効果を推測して適用しない。
	var confirmed: Dictionary[String, Variant] = _judgment_to_dict(judgment_result)
	confirmed["action_summary"] = intent.summary_ja
	confirmed["action_type"] = intent.action_type
	confirmed["target"] = intent.target
	confirmed["resolution_reason"] = tr("判定結果を確定しました。")
	confirmed["no_state_change"] = true
	confirmed["effects"] = tr("状態変更なし")
	return confirmed


func _confirmed_check_result(
	intent: IntentClassifier.Result,
	judgment_result: Judgment.Result,
	resolution: CheckResolver.CheckResolution,
) -> Dictionary[String, Variant]:
	var confirmed: Dictionary[String, Variant] = _judgment_to_dict(judgment_result)
	var resolution_data: Dictionary[String, Variant] = resolution.to_dict()
	confirmed["action_summary"] = intent.summary_ja
	confirmed["action_type"] = intent.action_type
	confirmed["target"] = intent.target
	confirmed["resolution"] = resolution_data
	confirmed["applied_effects"] = resolution_data["applied_effects"]
	confirmed["complication"] = resolution.complication_id
	confirmed["effects"] = _check_effects_summary(resolution)
	if not resolution.success:
		confirmed["action_summary"] = _unavailable_action_summary(
			intent.summary_ja,
			resolution.reason,
		)
	return confirmed


func _confirmed_action_result(
	intent: IntentClassifier.Result,
	resolution: ActionResolver.ActionResolution,
	judgment_result: Judgment.Result = null,
) -> Dictionary[String, Variant]:
	var resolution_data: Dictionary[String, Variant] = resolution.to_dict()
	var confirmed: Dictionary[String, Variant] = {}
	if judgment_result != null:
		confirmed = _judgment_to_dict(judgment_result)
	else:
		confirmed["tier"] = ""
	confirmed["action_summary"] = intent.summary_ja
	if not resolution.success:
		confirmed["action_summary"] = _unavailable_action_summary(
			intent.summary_ja,
			resolution.reason,
		)
	confirmed["action_type"] = intent.action_type
	confirmed["target"] = intent.target
	confirmed["resolution"] = resolution_data
	confirmed["applied_effects"] = resolution_data["applied_effects"]
	confirmed["effects"] = _action_effects_summary(resolution)
	confirmed["complication"] = ""
	return confirmed


func _build_pending_narration(
	player_input: String,
	intent: IntentClassifier.Result,
	confirmed_result: Dictionary[String, Variant],
) -> Dictionary[String, Variant]:
	return {
		"kind": "judgment" if intent.needs_roll else "action",
		"player_input": player_input,
		"intent": intent.to_dict(),
		"confirmed_result": confirmed_result.duplicate(true),
	}


func _run_pending_narration(resumed: bool) -> bool:
	if typeof(_state.pending_narration) != TYPE_DICTIONARY:
		_fail_turn(tr("描写に必要な確定結果がありません。"))
		_transition_to(State.IDLE)
		return false
	var pending: Dictionary = _state.pending_narration
	var confirmed_value: Variant = pending.get("confirmed_result", {})
	if typeof(confirmed_value) != TYPE_DICTIONARY:
		_fail_turn(tr("描写に必要な確定結果が破損しています。"))
		_transition_to(State.IDLE)
		return false
	var confirmed_result: Dictionary = confirmed_value

	_narration_skip_requested = false
	display_buffer = ""
	_narration_history_start_index = display_history.size()
	display_reset_requested.emit()
	_transition_to(State.NARRATING)
	narration_started.emit(resumed)

	var prompt_result: Narrator.PromptBuildResult = _narrator.build_prompt(
		_state,
		_scenario,
		rolling_summary,
		recent_logs,
		confirmed_result,
	)
	if not prompt_result.errors.is_empty():
		_publish_system_text(tr("GMは少し考え込んだ。……場面を仕切り直そう。"))
		narration_finished.emit(display_buffer)
		return await _finalize_turn(display_buffer)

	if not _begin_generation("narration"):
		narration_finished.emit(display_buffer)
		return await _finalize_turn(display_buffer)
	var opts: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	opts.max_tokens = NARRATION_MAX_TOKENS
	opts.temperature = NARRATION_TEMPERATURE
	_narration_generation_in_progress = true
	var output: Guardrails.OutputResult = await _guardrails.generate_filtered(
		prompt_result.prompt,
		opts,
	)
	_narration_generation_in_progress = false
	_end_generation("narration")

	if output.failed and display_buffer.is_empty():
		_publish_system_text(tr("GMは言葉をまとめられなかった。場面を仕切り直そう。"))
	elif (
		not _narration_skip_requested
		and display_buffer.is_empty()
		and not output.text.is_empty()
	):
		# 非ストリーミングbackendでも、Guardrailsの全文照合済み結果なら安全に表示できる。
		_publish_guarded_text(output.text)
	narration_finished.emit(display_buffer)
	return await _finalize_turn(display_buffer)


func _finalize_turn(narration_text: String) -> bool:
	if current_state != State.FINALIZING:
		_transition_to(State.FINALIZING)
	var pending_copy: Variant = _duplicate_variant(_state.pending_narration)
	recent_logs.append(_turn_log_text(pending_copy, narration_text))

	_state.pending_narration = null
	_pending_narration_saved = false
	if not _save_state():
		# クリアの保存に失敗した場合は、同一プロセスでも再開可能な未描写状態へ戻す。
		_state.pending_narration = pending_copy
		recent_logs.pop_back()
		# COMMITTING時の保存済みpendingはディスクに残っているため再生成可能。
		_pending_narration_saved = true
		_transition_to(State.IDLE)
		return false
	save_flushed.emit(_slot)

	var summary_changed: bool = await _fold_summary_if_needed()
	if summary_changed:
		# 畳み込み後のAI文脈も自己完結した同一セーブへ永続化する。
		if not _save_state():
			_transition_to(State.IDLE)
			return false
		save_flushed.emit(_slot)
	_transition_to(State.IDLE)
	return true


func _fold_summary_if_needed() -> bool:
	if not _summarizer.should_summarize(recent_logs):
		return false
	# Guardrailsがgeneration_finishedを受けて再開した同じsignal配送中に
	# Summarizerを待機状態へすると、直前の描写完了signalを要約結果として
	# 誤受信する。次フレームまで待ち、signal配送の境界も含めて生成を直列化する。
	await _wait_for_backend_signal_dispatch()
	if not _begin_generation("summary"):
		return false
	var summary_result: Summarizer.SummaryResult = await _summarizer.summarize(
		_state,
		rolling_summary,
		recent_logs,
	)
	_end_generation("summary")
	# 要約失敗時もSummarizerが構造化状態を使った安全なフォールバックを返す（INV-7）。
	rolling_summary = summary_result.summary
	recent_logs = summary_result.remaining_logs.duplicate()
	return true


func _wait_for_backend_signal_dispatch() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame


func _save_state() -> bool:
	_sync_context_to_state()
	var result: SaveManager.SaveResult = _save_manager.save(_slot, _state.serialize())
	if result.is_success():
		return true
	last_error = " / ".join(result.errors)
	turn_failed.emit(tr("ゲーム状態を保存できませんでした。"))
	return false


func _begin_generation(owner: String) -> bool:
	if _generation_active:
		last_error = "生成の並行実行を拒否しました: %s -> %s" % [_generation_owner, owner]
		turn_failed.emit(tr("AI生成処理が重複したため、ターンを安全に停止しました。"))
		return false
	_generation_active = true
	_generation_owner = owner
	return true


func _end_generation(owner: String) -> void:
	if not _generation_active or _generation_owner != owner:
		last_error = "生成ゲートの所有者が一致しません: %s / %s" % [_generation_owner, owner]
	_generation_active = false
	_generation_owner = ""


func _transition_to(next_state: State) -> void:
	var previous: State = current_state
	current_state = next_state
	state_history.append(next_state)
	state_changed.emit(previous, next_state)


func _publish_guarded_text(text: String) -> void:
	# Guardrailsの入力定型応答またはセンテンスバッファ通過済み断片だけがここへ来る。
	if text.is_empty():
		return
	display_buffer += text
	display_history.append(text)
	display_text_appended.emit(text)


func _publish_system_text(text: String) -> void:
	# AI自由出力ではなく、コード側のtr()済み定型文だけに限定する。
	_publish_guarded_text(text)


func _on_guarded_sentence_ready(text: String) -> void:
	if not _narration_generation_in_progress or _narration_skip_requested:
		return
	_publish_guarded_text(text)


func _on_guarded_generation_discarded(_attempt_index: int) -> void:
	if not _narration_generation_in_progress:
		return
	# 破棄対象の試行で先に確定した安全な文も、表示モデルからまとめて巻き戻す。
	display_buffer = ""
	display_history.resize(_narration_history_start_index)
	display_reset_requested.emit()


func _turn_log_text(pending_value: Variant, narration_text: String) -> String:
	var pending: Dictionary = {}
	if typeof(pending_value) == TYPE_DICTIONARY:
		pending = pending_value
	var intent_value: Variant = pending.get("intent", {})
	var intent: Dictionary = intent_value if typeof(intent_value) == TYPE_DICTIONARY else {}
	var confirmed_value: Variant = pending.get("confirmed_result", {})
	var confirmed: Dictionary = (
		confirmed_value if typeof(confirmed_value) == TYPE_DICTIONARY else {}
	)
	var judgment_log: Dictionary[String, Variant] = _judgment_log_from_confirmed(
		confirmed
	)
	return JSON.stringify(
		{
			"turn": _state.turn_count,
			"player_input": String(pending.get("player_input", "")),
			"action_summary": String(intent.get("summary_ja", "")),
			"judgment": judgment_log,
			"resolution": _duplicate_variant(confirmed.get("resolution", {})),
			"effects": String(confirmed.get("effects", "")),
			"narration": narration_text,
		}
	)


func _current_scene_summary() -> String:
	var scenes_value: Variant = _scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY:
		return ""
	var scenes: Array = scenes_value
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) == _state.scene_id:
			return String(scene.get("goal_ja", ""))
	return ""


func _judgment_to_dict(result: Judgment.Result) -> Dictionary[String, Variant]:
	return {
		"dice": _integer_array(result.dice),
		"kept": _integer_array(result.kept),
		"natural": int(result.natural),
		"ability_mod": int(result.ability_mod),
		"skill_bonus": int(result.skill_bonus),
		"applied_tag": result.applied_tag,
		"rejected_tags": result.rejected_tags.duplicate(),
		"situation_mod": int(result.situation_mod),
		"total": int(result.total),
		"tier": _tier_name(result.tier),
	}


func _request_for_roll(intent: IntentClassifier.Result) -> Judgment.Request:
	var request: Judgment.Request = Judgment.Request.new()
	request.ability = intent.request.ability
	request.skill_tags = intent.request.skill_tags.duplicate()
	request.situation_mod = intent.request.situation_mod
	request.roll_mode = intent.request.roll_mode
	if intent.action_type != "check" or typeof(intent.target) != TYPE_STRING:
		return request
	var target: String = intent.target
	if not target.begins_with("check:"):
		return request
	var check: Dictionary = _find_current_check(target.trim_prefix("check:"))
	if check.is_empty():
		return request
	request.ability = _ability_from_id(String(check.get("ability", "")))
	request.situation_mod = (
		request.situation_mod
		+ int(check.get("situation_mod", 0))
	)
	return request


func _find_current_check(check_id: String) -> Dictionary:
	var scenes_value: Variant = _scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY:
		return {}
	var scenes: Array = scenes_value
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) != _state.scene_id:
			continue
		var checks_value: Variant = scene.get("checks", [])
		if typeof(checks_value) != TYPE_ARRAY:
			return {}
		var checks: Array = checks_value
		for check_value: Variant in checks:
			if typeof(check_value) != TYPE_DICTIONARY:
				continue
			var check: Dictionary = check_value
			if String(check.get("id", "")) == check_id:
				return check
	return {}


func _ability_from_id(ability_id: String) -> Types.Ability:
	match ability_id:
		"DEX":
			return Types.Ability.DEX
		"CON":
			return Types.Ability.CON
		"INT":
			return Types.Ability.INT
		"WIS":
			return Types.Ability.WIS
		"CHA":
			return Types.Ability.CHA
		_:
			return Types.Ability.STR


func _tier_name(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.FUMBLE:
			return "FUMBLE"
		Types.ResultTier.FAILURE:
			return "FAILURE"
		Types.ResultTier.PARTIAL:
			return "PARTIAL"
		Types.ResultTier.SUCCESS:
			return "SUCCESS"
		Types.ResultTier.CRITICAL:
			return "CRITICAL"
		_:
			return ""


func _integer_array(values: Array[int]) -> Array[int]:
	var normalized: Array[int] = []
	for value: int in values:
		normalized.append(int(value))
	return normalized


func _judgment_log_from_confirmed(
	confirmed: Dictionary,
) -> Dictionary[String, Variant]:
	if not confirmed.has("dice"):
		return {}
	var fields: Array[String] = [
		"dice",
		"kept",
		"natural",
		"ability_mod",
		"skill_bonus",
		"applied_tag",
		"rejected_tags",
		"situation_mod",
		"total",
		"tier",
	]
	var result: Dictionary[String, Variant] = {}
	for field_name: String in fields:
		if confirmed.has(field_name):
			result[field_name] = _duplicate_variant(confirmed[field_name])
	return result


func _unavailable_action_summary(summary: String, reason: String) -> String:
	return tr("%s（実行不可: %s）") % [summary, reason]


func _action_effects_summary(
	resolution: ActionResolver.ActionResolution,
) -> String:
	if not resolution.success:
		return tr("実行不可: %s") % resolution.reason
	if resolution.applied_effects.is_empty():
		return tr("状態変更なし")
	return " / ".join(resolution.applied_effects)


func _check_effects_summary(
	resolution: CheckResolver.CheckResolution,
) -> String:
	if not resolution.success:
		return tr("実行不可: %s") % resolution.reason
	var prefix: String = resolution.branch
	if resolution.applied_effects.is_empty():
		return tr("%s: 効果なし") % prefix
	return "%s: %s" % [prefix, " / ".join(resolution.applied_effects)]


func _sync_context_to_state() -> void:
	_state.rolling_summary = rolling_summary
	_state.recent_logs = recent_logs.duplicate()


func _duplicate_variant(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary_value: Dictionary = value
		return dictionary_value.duplicate(true)
	if typeof(value) == TYPE_ARRAY:
		var array_value: Array = value
		return array_value.duplicate(true)
	return value


func _fail_turn(message: String) -> void:
	last_error = message
	turn_failed.emit(message)
