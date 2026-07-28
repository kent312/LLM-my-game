class_name Summarizer
extends RefCounted

signal summary_finished(result: Variant)
signal summary_failed(error: Variant)
signal _generation_settled(response: String, error: Variant)

const SUMMARIZE_PROMPT_PATH: String = "res://prompts/ja/summarize.txt"
const RECENT_TURN_LIMIT: int = 6
const FOLD_TURN_COUNT: int = 2
const SUMMARY_CHAR_LIMIT: int = 500
const STRUCTURED_CONTEXT_CHAR_LIMIT: int = 500
const FOLDED_LOG_CHAR_LIMIT: int = 1200
const OUTPUT_MAX_TOKENS: int = 300


class SummaryResult:
	var triggered: bool = false
	var summary: String = ""
	var remaining_logs: Array[String] = []
	var folded_logs: Array[String] = []
	var used_structured_fallback: bool = false
	var failed: bool = false
	var error: Variant = null
	var prompt: String = ""


class PromptBuildResult:
	var prompt: String = ""
	var errors: Array[String] = []


var prompt_history: Array[String] = []
var options_history: Array[Variant] = []

var _backend: LLMBackend
var _waiting_for_generation: bool = false
var _generation_in_progress: bool = false


func _init(backend: LLMBackend) -> void:
	_backend = backend
	assert(_backend != null, "SummarizerにはLLMBackendの注入が必要です。")
	if _backend == null:
		return
	_backend.generation_finished.connect(_on_backend_generation_finished)
	_backend.generation_failed.connect(_on_backend_generation_failed)


func should_summarize(recent_logs: Array) -> bool:
	return recent_logs.size() > RECENT_TURN_LIMIT


func summarize(
	state: GameState,
	existing_summary: Variant,
	recent_logs: Array,
) -> SummaryResult:
	var result: SummaryResult = SummaryResult.new()
	var normalized_logs: Array[String] = _normalize_logs(recent_logs)
	result.summary = _valid_summary_or_empty(existing_summary)
	result.remaining_logs = normalized_logs.duplicate()
	if not should_summarize(normalized_logs):
		return result

	result.triggered = true
	result.folded_logs = normalized_logs.slice(0, FOLD_TURN_COUNT)
	result.remaining_logs = normalized_logs.slice(FOLD_TURN_COUNT)
	var structured_context: String = _build_structured_context(state)
	if result.summary.is_empty():
		# INV-7: 要約の欠落・型破損時は構造化状態を真実として最低限の文脈を補う。
		result.summary = structured_context
		result.used_structured_fallback = true

	if _generation_in_progress or _waiting_for_generation:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"summary_generation_in_progress",
			tr("ローリングサマリー生成はすでに実行中です。"),
		)
		_apply_failed_fallback(result, structured_context)
		return result
	if _backend == null:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"summary_backend_unavailable",
			tr("ローリングサマリー生成にLLMバックエンドが設定されていません。"),
		)
		summary_failed.emit(result.error)
		_apply_failed_fallback(result, structured_context)
		return result

	var prompt_result: PromptBuildResult = _build_prompt(
		result.summary,
		structured_context,
		result.folded_logs,
	)
	if not prompt_result.errors.is_empty():
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"summary_prompt_unavailable",
			tr("ローリングサマリー用のプロンプトを準備できませんでした。"),
		)
		summary_failed.emit(result.error)
		_apply_failed_fallback(result, structured_context)
		return result

	_generation_in_progress = true
	prompt_history.clear()
	options_history.clear()
	result.prompt = prompt_result.prompt
	var opts: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	opts.max_tokens = OUTPUT_MAX_TOKENS
	opts.temperature = 0.2
	prompt_history.append(result.prompt)
	options_history.append(opts)

	_waiting_for_generation = true
	# intent_classifier.gdと同様に、同期signalの取りこぼしをcall_deferredで防ぐ。
	_backend.generate.call_deferred(result.prompt, opts)
	var settled: Array = await _generation_settled
	_generation_in_progress = false
	var generated_summary: String = String(settled[0]).strip_edges()
	result.error = settled[1]
	result.failed = result.error != null
	if result.failed:
		_apply_failed_fallback(result, structured_context)
		return result
	if generated_summary.is_empty():
		# INV-7: 空のAI要約も進行停止にせず、構造化状態と対象ログから再構築する。
		result.summary = _fallback_summary(
			structured_context,
			result.folded_logs,
			result.summary,
		)
		result.used_structured_fallback = true
	else:
		result.summary = generated_summary
	summary_finished.emit(result)
	return result


func _build_prompt(
	existing_summary: String,
	structured_context: String,
	folded_logs: Array[String],
) -> PromptBuildResult:
	var result: PromptBuildResult = PromptBuildResult.new()
	var prompt_template: String = _read_text(SUMMARIZE_PROMPT_PATH, result.errors)
	if not result.errors.is_empty():
		return result
	var values: Dictionary[String, String] = {
		"existing_summary": _truncate_text(existing_summary, SUMMARY_CHAR_LIMIT),
		"structured_context": _truncate_text(
			structured_context,
			STRUCTURED_CONTEXT_CHAR_LIMIT,
		),
		"folded_logs": _truncate_text(
			"\n\n".join(folded_logs),
			FOLDED_LOG_CHAR_LIMIT,
		),
	}
	result.prompt = _render_prompt(prompt_template, values)
	return result


func _on_backend_generation_finished(full_text: String) -> void:
	if not _waiting_for_generation:
		return
	_waiting_for_generation = false
	_generation_settled.emit(full_text, null)


func _on_backend_generation_failed(error: Variant) -> void:
	if not _waiting_for_generation:
		return
	_waiting_for_generation = false
	summary_failed.emit(error)
	_generation_settled.emit("", error)


func _normalize_logs(recent_logs: Array) -> Array[String]:
	var normalized: Array[String] = []
	for value: Variant in recent_logs:
		if typeof(value) == TYPE_STRING:
			normalized.append(String(value))
		else:
			normalized.append(JSON.stringify(value))
	return normalized


func _valid_summary_or_empty(summary: Variant) -> String:
	if typeof(summary) != TYPE_STRING:
		return ""
	var text: String = String(summary).strip_edges()
	if text.is_empty():
		return ""
	return text


func _build_structured_context(state: GameState) -> String:
	if state == null:
		return JSON.stringify({})
	var character: CharacterSheet = state.character
	var context: Dictionary[String, Variant] = {
		"scenario_id": state.scenario_id,
		"scene_id": state.scene_id,
		"turn_count": state.turn_count,
		"clock": state.clock,
		"flags": state.flags.duplicate(true),
		"active_enemies": state.active_enemies.duplicate(true),
	}
	if character != null:
		context["character"] = {
			"name": character.name,
			"description": character.description,
			"hp": character.hp.duplicate(true),
			"inventory": character.inventory.duplicate(true),
		}
	return JSON.stringify(context)


func _fallback_summary(
	structured_context: String,
	folded_logs: Array[String],
	existing_summary: String = "",
) -> String:
	var fallback_parts: Array[String] = [structured_context]
	if not existing_summary.is_empty() and existing_summary != structured_context:
		fallback_parts.append(existing_summary)
	if not folded_logs.is_empty():
		fallback_parts.append("\n".join(folded_logs))
	return "\n".join(fallback_parts)


func _apply_failed_fallback(result: SummaryResult, structured_context: String) -> void:
	# 生成失敗でも畳み込み対象を要約側へ残し、ログ消失を防ぐ（INV-7）。
	result.summary = _fallback_summary(
		structured_context,
		result.folded_logs,
		result.summary,
	)
	result.used_structured_fallback = true


func _render_prompt(template: String, values: Dictionary[String, String]) -> String:
	# 挿入値を再走査しない1パス置換により、ログ中のプレースホルダを展開しない（ARCH-9）。
	var rendered: String = ""
	var cursor: int = 0
	while cursor < template.length():
		var placeholder_start: int = template.find("{{", cursor)
		if placeholder_start < 0:
			rendered += template.substr(cursor)
			break
		rendered += template.substr(cursor, placeholder_start - cursor)
		var placeholder_end: int = template.find("}}", placeholder_start + 2)
		if placeholder_end < 0:
			rendered += template.substr(placeholder_start)
			break
		var placeholder: String = template.substr(
			placeholder_start + 2,
			placeholder_end - placeholder_start - 2,
		)
		if values.has(placeholder):
			rendered += values[placeholder]
		else:
			rendered += template.substr(
				placeholder_start,
				placeholder_end + 2 - placeholder_start,
			)
		cursor = placeholder_end + 2
	return rendered


func _read_text(path: String, errors: Array[String]) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("ファイルを開けません: %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return ""
	return file.get_as_text()


func _truncate_text(text: String, character_limit: int) -> String:
	if text.length() <= character_limit:
		return text
	return text.left(character_limit - 1) + "…"
