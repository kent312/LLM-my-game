## 確定判定結果はDictionaryを標準形式とする。
## Judgment.Resultも受け入れるが、全判定根拠をDictionaryへ変換して同じ整形経路に流す。
class_name Narrator
extends RefCounted

signal token_streamed(text: String)
signal generation_finished(full_text: String)
signal generation_failed(error: Variant)
signal _generation_settled(response: String, error: Variant)

const SYSTEM_PROMPT_PATH: String = "res://prompts/ja/system_gm.txt"
const NARRATE_PROMPT_PATH: String = "res://prompts/ja/narrate.txt"
const MAX_RECENT_TURNS: int = 6
const SYSTEM_PROMPT_CHAR_LIMIT: int = 600
const CHARACTER_SUMMARY_CHAR_LIMIT: int = 200
const SCENE_CONTEXT_CHAR_LIMIT: int = 400
const ROLLING_SUMMARY_CHAR_LIMIT: int = 500
const RECENT_LOG_CHAR_LIMIT: int = 1200
const CONFIRMED_RESULT_CHAR_LIMIT: int = 150
const OUTPUT_MAX_TOKENS: int = 400
const CHARACTER_REMOVABLE_FIELDS: Array[String] = [
	"description",
	"inventory",
	"money",
	"skills",
	"hp",
	"abilities",
	"name",
]
const SCENE_REMOVABLE_FIELDS: Array[String] = ["mood_tags", "npcs"]
const CONFIRMED_OPTIONAL_FIELDS: Array[String] = [
	"applied_effects",
	"rejected_tags",
	"dice",
	"kept",
	"ability_mod",
	"skill_bonus",
	"situation_mod",
	"natural",
	"total",
	"applied_tag",
]
const CONFIRMED_REMOVABLE_FIELDS: Array[String] = [
	"rejected_tags",
	"dice",
	"kept",
	"ability_mod",
	"skill_bonus",
	"situation_mod",
	"applied_effects",
]


class GenerationResult:
	var text: String = ""
	var failed: bool = false
	var error: Variant = null
	var prompt: String = ""


class PromptBuildResult:
	var prompt: String = ""
	var external_context: Dictionary[String, String] = {}
	var errors: Array[String] = []


var prompt_history: Array[String] = []
var options_history: Array[Variant] = []

var _backend: LLMBackend
var _waiting_for_generation: bool = false
var _generation_in_progress: bool = false


func _init(backend: LLMBackend) -> void:
	_backend = backend
	assert(_backend != null, "NarratorにはLLMBackendの注入が必要です。")
	if _backend == null:
		return
	_backend.token_streamed.connect(_on_backend_token_streamed)
	_backend.generation_finished.connect(_on_backend_generation_finished)
	_backend.generation_failed.connect(_on_backend_generation_failed)


func narrate(
	state: GameState,
	scenario: Scenario,
	rolling_summary: Variant,
	recent_logs: Array,
	confirmed_result: Variant,
) -> GenerationResult:
	var result: GenerationResult = GenerationResult.new()
	if _generation_in_progress or _waiting_for_generation:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"narration_generation_in_progress",
			tr("描写生成はすでに実行中です。"),
		)
		generation_failed.emit(result.error)
		return result
	if _backend == null:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"narration_backend_unavailable",
			tr("描写生成にLLMバックエンドが設定されていません。"),
		)
		generation_failed.emit(result.error)
		return result

	var prompt_result: PromptBuildResult = build_prompt(
		state,
		scenario,
		rolling_summary,
		recent_logs,
		confirmed_result,
	)
	if not prompt_result.errors.is_empty():
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"narration_prompt_unavailable",
			tr("描写生成用のプロンプトを準備できませんでした。"),
		)
		generation_failed.emit(result.error)
		return result

	_generation_in_progress = true
	prompt_history.clear()
	options_history.clear()
	result.prompt = prompt_result.prompt
	var opts: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	opts.max_tokens = OUTPUT_MAX_TOKENS
	opts.temperature = 0.8
	opts.external_context = prompt_result.external_context.duplicate(true)
	prompt_history.append(result.prompt)
	options_history.append(opts)

	_waiting_for_generation = true
	# 同期発火するバックエンドでもawait登録前に通知を失わないよう遅延する（ARCH-7）。
	_backend.generate.call_deferred(result.prompt, opts)
	var settled: Array = await _generation_settled
	_generation_in_progress = false
	result.text = String(settled[0])
	result.error = settled[1]
	result.failed = result.error != null
	return result


func build_prompt(
	state: GameState,
	scenario: Scenario,
	rolling_summary: Variant,
	recent_logs: Array,
	confirmed_result: Variant,
) -> PromptBuildResult:
	# TurnMachineは出力ガードレールを必須化するためnarrate()ではなく、
	# 本メソッドで組み立てたpromptをGuardrails.generate_filtered()へ渡す。
	var result: PromptBuildResult = PromptBuildResult.new()
	var system_prompt: String = _read_text(SYSTEM_PROMPT_PATH, result.errors)
	var narrate_template: String = _read_text(NARRATE_PROMPT_PATH, result.errors)
	if not result.errors.is_empty():
		return result
	system_prompt = system_prompt.strip_edges()
	if system_prompt.length() > SYSTEM_PROMPT_CHAR_LIMIT:
		result.errors.append(
			"システムプロンプトが文字数上限を超えています（%d > %d）。"
			% [system_prompt.length(), SYSTEM_PROMPT_CHAR_LIMIT]
		)

	# §6.3: テンプレートの並びを唯一の順序定義とし、挿入値は予算内に収める。
	# 日本語用の軽量実装では文字数をトークン数の保守的な近似として扱う。
	var values: Dictionary[String, String] = {
		"system_prompt": system_prompt,
		"character_summary": _build_character_summary(state),
		"scene_context": _build_scene_context(state, scenario),
		"rolling_summary": _truncate_text(
			_normalize_summary(rolling_summary),
			ROLLING_SUMMARY_CHAR_LIMIT,
		),
		"recent_logs": _build_recent_logs(recent_logs),
		"confirmed_result": _build_confirmed_result(confirmed_result),
	}
	result.prompt = _render_prompt(narrate_template, values)
	result.external_context = {
		"system_prompt": (
			system_prompt
			+ "\n\n"
			+ tr("確定済みの結果を変更せず、場面描写だけを返してください。")
		),
		"character_sheet_summary": values["character_summary"],
		"current_scene": (
			values["scene_context"]
			+ "\n\n"
			+ tr("今回の確定情報:")
			+ "\n"
			+ values["confirmed_result"]
		),
		"conversation_history": values["recent_logs"],
		"conversation_summary": values["rolling_summary"],
	}
	return result


func _on_backend_token_streamed(text: String) -> void:
	if not _waiting_for_generation:
		return
	# ARCH-7: バックエンドの断片を加工せず表示層へ中継する。
	token_streamed.emit(text)


func _on_backend_generation_finished(full_text: String) -> void:
	if not _waiting_for_generation:
		return
	_waiting_for_generation = false
	generation_finished.emit(full_text)
	_generation_settled.emit(full_text, null)


func _on_backend_generation_failed(error: Variant) -> void:
	if not _waiting_for_generation:
		return
	_waiting_for_generation = false
	generation_failed.emit(error)
	_generation_settled.emit("", error)


func _build_character_summary(state: GameState) -> String:
	if state == null or state.character == null:
		return JSON.stringify({})
	var character: CharacterSheet = state.character
	var summary: Dictionary[String, Variant] = {
		"name": character.name,
		"description": character.description,
		"abilities": character.abilities.duplicate(true),
		"hp": character.hp.duplicate(true),
		"skills": character.skills.duplicate(),
		"specialties": character.specialties.duplicate(true),
		"inventory": character.inventory.duplicate(true),
		"money": character.money,
		"xp": character.xp,
	}
	return _serialize_with_field_budget(
		summary,
		CHARACTER_SUMMARY_CHAR_LIMIT,
		CHARACTER_REMOVABLE_FIELDS,
	)


func _build_scene_context(state: GameState, scenario: Scenario) -> String:
	var scene: Dictionary = _find_current_scene(state, scenario)
	var context: Dictionary[String, Variant] = {
		"scenario_id": "" if state == null else state.scenario_id,
		"scene_id": "" if state == null else state.scene_id,
		"goal_ja": scene.get("goal_ja", ""),
		"npcs": _scene_npcs_for_prompt(scene),
		"mood_tags": _string_array(scene.get("mood_tags", [])),
	}
	return _serialize_with_field_budget(
		context,
		SCENE_CONTEXT_CHAR_LIMIT,
		SCENE_REMOVABLE_FIELDS,
	)


func _scene_npcs_for_prompt(scene: Dictionary) -> Array[Dictionary]:
	var prompt_npcs: Array[Dictionary] = []
	var npcs_value: Variant = scene.get("npcs", [])
	if typeof(npcs_value) != TYPE_ARRAY:
		return prompt_npcs
	var npcs: Array = npcs_value
	for npc_value: Variant in npcs:
		if typeof(npc_value) != TYPE_DICTIONARY:
			continue
		var npc: Dictionary = npc_value
		prompt_npcs.append(
			{
				"id": String(npc.get("id", "")),
				"name": String(npc.get("name", "")),
				"persona_ja": String(npc.get("persona_ja", "")),
			}
		)
	return prompt_npcs


func _build_recent_logs(recent_logs: Array) -> String:
	var first_index: int = maxi(0, recent_logs.size() - MAX_RECENT_TURNS)
	var selected: Array[String] = []
	var used_characters: int = 0
	for index: int in range(recent_logs.size() - 1, first_index - 1, -1):
		var value: Variant = recent_logs[index]
		var normalized: String = ""
		if typeof(value) == TYPE_STRING:
			normalized = String(value)
		else:
			normalized = JSON.stringify(value)
		var separator_length: int = 0 if selected.is_empty() else 2
		var available: int = RECENT_LOG_CHAR_LIMIT - used_characters - separator_length
		if available <= 0:
			break
		if normalized.length() > available:
			# 最新ターン単体が上限を超える場合だけ、自由テキストとして切り詰める。
			if selected.is_empty():
				selected.push_front(_truncate_text(normalized, available))
			break
		selected.push_front(normalized)
		used_characters += separator_length + normalized.length()
	return "\n\n".join(selected)


func _build_confirmed_result(confirmed_result: Variant) -> String:
	var source: Dictionary[String, Variant] = _confirmed_result_dictionary(confirmed_result)
	var normalized: Dictionary[String, Variant] = {
		"tier": _tier_name(source.get("tier", "")),
		"action_summary": String(
			source.get("action_summary", source.get("summary_ja", ""))
		),
		"complication": String(
			source.get(
				"complication",
				source.get("confirmed_complication", source.get("complication_id", "")),
			)
		),
		# 効果の要点は文字数予算でも削除せず、適用済み事実を描写へ必ず渡す。
		"effects": _truncate_text(String(source.get("effects", "")), 80),
	}
	for field_name: String in CONFIRMED_OPTIONAL_FIELDS:
		if source.has(field_name):
			normalized[field_name] = source[field_name]
	return _serialize_with_field_budget(
		normalized,
		CONFIRMED_RESULT_CHAR_LIMIT,
		CONFIRMED_REMOVABLE_FIELDS,
	)


func _confirmed_result_dictionary(confirmed_result: Variant) -> Dictionary[String, Variant]:
	var normalized: Dictionary[String, Variant] = {}
	if confirmed_result is Judgment.Result:
		var judgment_result: Judgment.Result = confirmed_result
		normalized["dice"] = judgment_result.dice.duplicate()
		normalized["kept"] = judgment_result.kept.duplicate()
		normalized["natural"] = judgment_result.natural
		normalized["ability_mod"] = judgment_result.ability_mod
		normalized["skill_bonus"] = judgment_result.skill_bonus
		normalized["applied_tag"] = judgment_result.applied_tag
		normalized["rejected_tags"] = judgment_result.rejected_tags.duplicate()
		normalized["situation_mod"] = judgment_result.situation_mod
		normalized["total"] = judgment_result.total
		normalized["tier"] = judgment_result.tier
		return normalized
	if typeof(confirmed_result) == TYPE_DICTIONARY:
		var source: Dictionary = confirmed_result
		for key_value: Variant in source.keys():
			if typeof(key_value) == TYPE_STRING:
				var key: String = key_value
				normalized[key] = source[key]
	return normalized


func _serialize_with_field_budget(
	data: Dictionary[String, Variant],
	character_limit: int,
	removable_fields: Array[String],
) -> String:
	var compact: Dictionary[String, Variant] = data.duplicate(true)
	var serialized: String = JSON.stringify(compact)
	for field_name: String in removable_fields:
		if serialized.length() <= character_limit:
			break
		compact.erase(field_name)
		serialized = JSON.stringify(compact)
	return serialized


func _normalize_summary(summary: Variant) -> String:
	if typeof(summary) != TYPE_STRING:
		return ""
	return String(summary)


func _find_current_scene(state: GameState, scenario: Scenario) -> Dictionary:
	if state == null or scenario == null:
		return {}
	var scenes_value: Variant = scenario.data.get("scenes", [])
	if typeof(scenes_value) != TYPE_ARRAY:
		return {}
	var scenes: Array = scenes_value
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) == state.scene_id:
			return scene
	return {}


func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return result
	var values: Array = value
	for entry: Variant in values:
		if typeof(entry) == TYPE_STRING:
			result.append(String(entry))
	return result


func _tier_name(value: Variant) -> String:
	if typeof(value) == TYPE_STRING:
		return String(value)
	if typeof(value) != TYPE_INT:
		return ""
	match int(value):
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


func _render_prompt(template: String, values: Dictionary[String, String]) -> String:
	# 挿入値を再走査しない1パス置換により、ログ内の{{placeholder}}を展開しない（ARCH-9）。
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
