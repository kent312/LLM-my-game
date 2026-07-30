class_name IntentClassifier
extends RefCounted

signal _generation_settled(response: String, failed: bool)

const PROMPT_PATH: String = "res://prompts/ja/intent.txt"
const GRAMMAR_PATH: String = "res://game/data/generated/intent.gbnf"
const SCHEMA_PATH: String = "res://game/data/generated/intent_schema.json"
const TAXONOMY_PATH: String = "res://game/data/skill_tags.json"
const STATE_VERBS_PATH: String = "res://game/data/state_verbs.json"
const TARGET_ENUM_PLACEHOLDER: String = "__TARGET_ENUM_RUNTIME__"

const REQUIRED_FIELDS: Array[String] = [
	"action_type",
	"ability",
	"skill_tags",
	"target",
	"difficulty",
	"needs_roll",
	"summary_ja",
]
const ACTION_TYPES: Array[String] = ["check", "talk", "move", "item", "attack", "other"]
const ABILITY_IDS: Array[String] = ["STR", "DEX", "CON", "INT", "WIS", "CHA"]
const DIFFICULTIES: Array[String] = ["easy", "normal", "hard"]
const TARGET_REQUIRED_ACTIONS: Array[String] = ["move", "item", "talk", "attack"]
const ATTACK_ABILITIES: Array[String] = ["STR", "DEX"]

const FAILURE_GENERAL: String = "general"
const FAILURE_REQUIRED_TARGET: String = "required_target"
const FAILURE_CHECK_TARGET: String = "check_target"


class Result:
	var action_type: String = "other"
	var ability_id: String = "STR"
	var skill_tags: Array[String] = []
	var target: Variant = null
	var difficulty: String = "normal"
	var difficulty_mod: int = 0
	var needs_roll: bool = false
	var summary_ja: String = ""
	var request: Judgment.Request = null
	var executable: bool = true
	var no_state_change: bool = false
	var confirmation_response: String = ""
	var allowed_targets: Array[Variant] = []
	var validation_retry_count: int = 0
	var other_reclassification_count: int = 0
	var detected_state_verbs: Array[String] = []
	var audit_path: Array[String] = []
	# 診断・テスト専用でUIには表示しないため、ここへ入る文字列はtr()の対象外とする。
	var validation_errors: Array[String] = []


	func to_dict() -> Dictionary[String, Variant]:
		return {
			"action_type": action_type,
			"ability": ability_id,
			"skill_tags": skill_tags.duplicate(),
			"target": target,
			"difficulty": difficulty,
			"difficulty_mod": difficulty_mod,
			"needs_roll": needs_roll,
			"summary_ja": summary_ja,
			"executable": executable,
			"no_state_change": no_state_change,
			"confirmation_response": confirmation_response,
			"allowed_targets": allowed_targets.duplicate(true),
			"validation_retry_count": validation_retry_count,
			"other_reclassification_count": other_reclassification_count,
			"detected_state_verbs": detected_state_verbs.duplicate(),
			"audit_path": audit_path.duplicate(),
			"validation_errors": validation_errors.duplicate(),
		}


class ValidationResult:
	var intent: Dictionary = {}
	var errors: Array[String] = []
	var failure_kind: String = FAILURE_GENERAL


	func is_valid() -> bool:
		return errors.is_empty()


class GenerationResult:
	var response: String = ""
	var failed: bool = false


class RuntimeConstraints:
	var grammar: String = ""
	var schema: Dictionary = {}
	var errors: Array[String] = []


class Taxonomy:
	var ids: Dictionary[String, bool] = {}
	var hints: Dictionary[String, String] = {}
	var errors: Array[String] = []


class StateVerbDetection:
	var verbs: Array[String] = []
	var errors: Array[String] = []


	func is_available() -> bool:
		return errors.is_empty()


var prompt_history: Array[String] = []
var options_history: Array[Variant] = []

var _backend: LLMBackend
var _waiting_for_generation: bool = false
var _classification_in_progress: bool = false


func _init(backend: LLMBackend) -> void:
	_backend = backend
	assert(_backend != null, "IntentClassifierにはLLMBackendの注入が必要です。")
	if _backend == null:
		return
	_backend.generation_finished.connect(_on_generation_finished)
	_backend.generation_failed.connect(_on_generation_failed)


func classify(
	player_input: String,
	scene_summary: String,
	state: GameState,
	scenario: Scenario,
) -> Result:
	# 同一インスタンスの並行分類は履歴とシグナル待機を共有してしまうため明示的に拒否する。
	if _classification_in_progress or _waiting_for_generation:
		return _fallback_result(
			build_allowed_targets(state, scenario),
			["意図分類処理の実行中に再入が要求されました。"],
			["classification_reentry", "fallback_other"],
		)
	if _backend == null:
		return _fallback_result(
			build_allowed_targets(state, scenario),
			["LLMBackendが設定されていません。"],
			["backend_unavailable", "fallback_other"],
		)
	_classification_in_progress = true
	var result: Result = await _classify_internal(
		player_input,
		scene_summary,
		state,
		scenario,
	)
	_classification_in_progress = false
	return result


func _classify_internal(
	player_input: String,
	scene_summary: String,
	state: GameState,
	scenario: Scenario,
) -> Result:
	prompt_history.clear()
	options_history.clear()
	var allowed_targets: Array[Variant] = build_allowed_targets(state, scenario)
	var taxonomy: Taxonomy = _load_taxonomy()
	var constraints: RuntimeConstraints = _build_runtime_constraints(allowed_targets)
	var preparation_errors: Array[String] = []
	preparation_errors.append_array(taxonomy.errors)
	preparation_errors.append_array(constraints.errors)
	var prompt_template: String = _read_text(PROMPT_PATH, preparation_errors)
	if not preparation_errors.is_empty():
		return _fallback_result(
			allowed_targets,
			preparation_errors,
			["preparation_failed", "fallback_other"],
		)

	var prompt_values: Dictionary[String, String] = {
		"player_input": player_input,
		"scene_summary": scene_summary,
		"character_skills": _build_character_skills(state, taxonomy),
		"skill_tag_ids": _build_taxonomy_entries(taxonomy),
		"allowed_targets": JSON.stringify(allowed_targets),
		"checks": _build_check_hints(state, scenario),
		"validation_errors": "",
		"state_change_verbs": "",
	}
	var first_generation: GenerationResult = await _generate_once(
		_render_prompt(prompt_template, prompt_values),
		constraints,
		player_input,
	)
	var first_validation: ValidationResult = _validate_response(
		first_generation,
		allowed_targets,
		taxonomy.ids,
	)
	if first_validation.is_valid():
		var first_result: Result = _result_from_intent(
			first_validation.intent,
			allowed_targets,
		)
		first_result.audit_path = ["initial_generation", "validated"]
		return await _apply_other_safety(
			first_result,
			player_input,
			prompt_template,
			prompt_values,
			constraints,
			allowed_targets,
			taxonomy.ids,
		)

	prompt_values["validation_errors"] = "\n".join(first_validation.errors)
	var second_generation: GenerationResult = await _generate_once(
		_render_prompt(prompt_template, prompt_values),
		constraints,
		player_input,
	)
	var second_validation: ValidationResult = _validate_response(
		second_generation,
		allowed_targets,
		taxonomy.ids,
	)
	if second_validation.is_valid():
		var retried_result: Result = _result_from_intent(
			second_validation.intent,
			allowed_targets,
		)
		retried_result.validation_retry_count = 1
		retried_result.validation_errors = first_validation.errors.duplicate()
		retried_result.audit_path = [
			"initial_generation",
			"validation_failed",
			"validation_retry",
			"validated",
		]
		return await _apply_other_safety(
			retried_result,
			player_input,
			prompt_template,
			prompt_values,
			constraints,
			allowed_targets,
			taxonomy.ids,
		)

	var combined_errors: Array[String] = first_validation.errors.duplicate()
	combined_errors.append_array(second_validation.errors)
	# §6.2: check-target不正から始まった再生成は、2回目の壊れ方に関係なく
	# 初回の構造化済み意図を使い、宣言的効果のない自由判定へ安全側に倒す。
	if (
		first_validation.failure_kind == FAILURE_CHECK_TARGET
		or second_validation.failure_kind == FAILURE_CHECK_TARGET
	):
		var check_intent: Dictionary = first_validation.intent.duplicate(true)
		if (
			second_validation.failure_kind == FAILURE_CHECK_TARGET
			and not second_validation.intent.is_empty()
		):
			check_intent = second_validation.intent.duplicate(true)
		check_intent["target"] = null
		var free_check: Result = _result_from_intent(check_intent, allowed_targets)
		free_check.validation_retry_count = 1
		free_check.validation_errors = combined_errors
		free_check.audit_path = [
			"initial_generation",
			"invalid_check_target",
			"validation_retry",
			"validation_failed",
			"free_check_confirmed",
		]
		return free_check
	if second_validation.failure_kind == FAILURE_REQUIRED_TARGET:
		var unavailable: Result = _result_from_intent(
			second_validation.intent,
			allowed_targets,
		)
		unavailable.target = null
		unavailable.executable = false
		unavailable.no_state_change = false
		unavailable.confirmation_response = tr(
			"どこへ／何を対象にするか、もう少し具体的に教えてください。"
		)
		unavailable.validation_retry_count = 1
		unavailable.validation_errors = combined_errors
		unavailable.audit_path = [
			"initial_generation",
			"validation_failed",
			"validation_retry",
			"required_target_unavailable",
		]
		return unavailable
	return _fallback_result(
		allowed_targets,
		combined_errors,
		[
			"initial_generation",
			"validation_failed",
			"validation_retry",
			"validation_failed",
			"fallback_other",
		],
		1,
	)


func build_allowed_targets(state: GameState, scenario: Scenario) -> Array[Variant]:
	var targets: Array[Variant] = []
	var seen: Dictionary[String, bool] = {}
	var scene: Dictionary = _find_current_scene(state, scenario)

	var exits_value: Variant = scene.get("exits", [])
	if typeof(exits_value) == TYPE_ARRAY:
		var exits: Array = exits_value
		for exit_value: Variant in exits:
			if typeof(exit_value) != TYPE_DICTIONARY:
				continue
			var exit_data: Dictionary = exit_value
			_append_target(targets, seen, "exit:", exit_data.get("goto"))

	for item: Dictionary in state.character.inventory:
		if int(item.get("count", 0)) > 0:
			_append_target(targets, seen, "item:", item.get("item_id"))

	var npcs_value: Variant = scene.get("npcs", [])
	if typeof(npcs_value) == TYPE_ARRAY:
		var npcs: Array = npcs_value
		for npc_value: Variant in npcs:
			if typeof(npc_value) != TYPE_DICTIONARY:
				continue
			var npc: Dictionary = npc_value
			_append_target(targets, seen, "npc:", npc.get("id"))

	for enemy: Dictionary in state.active_enemies:
		_append_target(targets, seen, "enemy:", enemy.get("enemy_id"))

	var checks_value: Variant = scene.get("checks", [])
	if typeof(checks_value) == TYPE_ARRAY:
		var checks: Array = checks_value
		for check_value: Variant in checks:
			if typeof(check_value) != TYPE_DICTIONARY:
				continue
			var check: Dictionary = check_value
			_append_target(targets, seen, "check:", check.get("id"))

	targets.append(null)
	return targets


func detect_state_change_verbs(player_input: String) -> StateVerbDetection:
	var result: StateVerbDetection = StateVerbDetection.new()
	var source_text: String = _read_text(STATE_VERBS_PATH, result.errors)
	if not result.errors.is_empty():
		return result
	var json: JSON = JSON.new()
	if json.parse(source_text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		result.errors.append("状態変更語彙辞書を解析できません。")
		return result
	var root: Dictionary = json.data

	var terms_value: Variant = root.get("terms", [])
	if typeof(terms_value) != TYPE_ARRAY:
		result.errors.append("状態変更語彙辞書のtermsが配列ではありません。")
		return result
	var terms: Array = terms_value
	for term_value: Variant in terms:
		if typeof(term_value) != TYPE_STRING:
			result.errors.append("状態変更語彙辞書のtermsに文字列以外があります。")
			return result
		var term: String = term_value
		if not term.is_empty() and player_input.contains(term):
			_append_unique(result.verbs, term)

	var patterns_value: Variant = root.get("patterns", [])
	if typeof(patterns_value) != TYPE_ARRAY:
		result.errors.append("状態変更語彙辞書のpatternsが配列ではありません。")
		return result
	var patterns: Array = patterns_value
	for pattern_value: Variant in patterns:
		if typeof(pattern_value) != TYPE_STRING:
			result.errors.append("状態変更語彙辞書のpatternsに文字列以外があります。")
			return result
		var regex: RegEx = RegEx.new()
		if regex.compile(String(pattern_value)) != OK:
			result.errors.append("状態変更語彙辞書に不正な正規表現があります。")
			return result
		for matched: RegExMatch in regex.search_all(player_input):
			_append_unique(result.verbs, matched.get_string())
	return result


func _apply_other_safety(
	result: Result,
	player_input: String,
	prompt_template: String,
	prompt_values: Dictionary[String, String],
	constraints: RuntimeConstraints,
	allowed_targets: Array[Variant],
	valid_tag_ids: Dictionary[String, bool],
) -> Result:
	if result.action_type != "other":
		return result
	result.needs_roll = false
	result.request = _build_request(result.ability_id, result.skill_tags, result.difficulty_mod)
	# §7.1: otherだけは入力中の状態変更語彙を軽量検出し、状態変更要求の素通りを防ぐ。
	# 対象IDはここでは推測せず、検出語を明示した再分類と通常のtarget検証へ戻す（INV-3）。
	var detection: StateVerbDetection = detect_state_change_verbs(player_input)
	if not detection.is_available():
		result.validation_errors.append_array(detection.errors)
		result.executable = false
		result.no_state_change = false
		result.confirmation_response = tr("何を／どこへ、を具体的に教えてください。")
		result.audit_path.append("state_verbs_unavailable")
		result.audit_path.append("other_execution_unavailable")
		return result
	var detected: Array[String] = detection.verbs
	result.detected_state_verbs = detected.duplicate()
	if detected.is_empty():
		result.no_state_change = true
		result.audit_path.append("other_no_state_change")
		return result

	result.audit_path.append("state_change_verb_detected")
	result.audit_path.append("other_reclassification")
	result.other_reclassification_count = 1
	var reclassification_values: Dictionary[String, String] = prompt_values.duplicate()
	reclassification_values["validation_errors"] = ""
	reclassification_values["state_change_verbs"] = "、".join(detected)
	var generation: GenerationResult = await _generate_once(
		_render_prompt(prompt_template, reclassification_values),
		constraints,
		player_input,
	)
	var validation: ValidationResult = _validate_response(
		generation,
		allowed_targets,
		valid_tag_ids,
	)
	if validation.is_valid() and String(validation.intent["action_type"]) != "other":
		var reclassified: Result = _result_from_intent(validation.intent, allowed_targets)
		reclassified.validation_retry_count = result.validation_retry_count
		reclassified.other_reclassification_count = 1
		reclassified.detected_state_verbs = detected.duplicate()
		reclassified.validation_errors = result.validation_errors.duplicate()
		reclassified.audit_path = result.audit_path.duplicate()
		reclassified.audit_path.append("reclassified")
		return reclassified

	if not validation.is_valid():
		result.validation_errors.append_array(validation.errors)
	result.executable = false
	result.no_state_change = false
	result.confirmation_response = tr("何を／どこへ、を具体的に教えてください。")
	result.audit_path.append("other_execution_unavailable")
	return result


func _generate_once(
	prompt: String,
	constraints: RuntimeConstraints,
	player_input: String,
) -> GenerationResult:
	var result: GenerationResult = GenerationResult.new()
	if _waiting_for_generation:
		result.failed = true
		return result
	if _backend == null:
		result.failed = true
		return result
	var opts: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	opts.max_tokens = 400
	opts.temperature = 0.1
	if _backend.supports_constrained_output():
		opts.grammar = constraints.grammar
		opts.json_schema = constraints.schema.duplicate(true)
	opts.external_context = {
		"system_prompt": _prompt_without_player_input(prompt, player_input),
		"player_input": player_input,
	}
	prompt_history.append(prompt)
	options_history.append(opts)
	_waiting_for_generation = true
	# 実装バックエンドがsignalを同期発火しても、await登録前に結果を失わないよう遅延呼び出しにする。
	# これによりUIスレッドを待機で塞がないLLMBackend契約も維持する（ARCH-7）。
	_backend.generate.call_deferred(prompt, opts)
	var settled: Array = await _generation_settled
	_waiting_for_generation = false
	result.response = String(settled[0])
	result.failed = bool(settled[1])
	return result


func _prompt_without_player_input(prompt: String, player_input: String) -> String:
	if player_input.is_empty():
		return prompt
	# 外部APIでは自由入力をsystemロールへ混ぜず、userロールだけに置く。
	# ローカルバックエンドへ渡す元promptは変更しない。
	return prompt.replace(player_input, tr("（プレイヤー入力はuserメッセージを参照）"))


func _validate_response(
	generation: GenerationResult,
	allowed_targets: Array[Variant],
	valid_tag_ids: Dictionary[String, bool],
) -> ValidationResult:
	var result: ValidationResult = ValidationResult.new()
	# errorsはバックエンド品質の診断専用でUIへ直接表示しないため、tr()を通さない。
	if generation.failed:
		result.errors.append("バックエンドの生成に失敗しました。")
		return result
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(generation.response)
	if parse_error != OK:
		result.errors.append(
			"JSONの解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return result
	if typeof(json.data) != TYPE_DICTIONARY:
		result.errors.append("意図分類のルートはJSONオブジェクトである必要があります。")
		return result
	var raw: Dictionary = json.data
	for field_name: String in REQUIRED_FIELDS:
		if not raw.has(field_name):
			result.errors.append("%s: 必須項目です。" % field_name)
	for key_value: Variant in raw.keys():
		if typeof(key_value) != TYPE_STRING or not REQUIRED_FIELDS.has(String(key_value)):
			result.errors.append("スキーマにないフィールドです: %s" % str(key_value))
	if not result.errors.is_empty():
		return result

	_validate_string_enum(raw, "action_type", ACTION_TYPES, result.errors)
	_validate_string_enum(raw, "ability", ABILITY_IDS, result.errors)
	_validate_string_enum(raw, "difficulty", DIFFICULTIES, result.errors)
	if typeof(raw["needs_roll"]) != TYPE_BOOL:
		result.errors.append("needs_roll: boolである必要があります。")
	if typeof(raw["summary_ja"]) != TYPE_STRING:
		result.errors.append("summary_ja: 文字列である必要があります。")
	if typeof(raw["skill_tags"]) != TYPE_ARRAY:
		result.errors.append("skill_tags: 配列である必要があります。")
	else:
		var raw_tags: Array = raw["skill_tags"]
		for index: int in range(raw_tags.size()):
			var tag_value: Variant = raw_tags[index]
			if typeof(tag_value) != TYPE_STRING:
				result.errors.append("skill_tags[%d]: 文字列である必要があります。" % index)
				continue
			var tag_id: String = tag_value
			if not valid_tag_ids.has(tag_id):
				result.errors.append(
					"skill_tags[%d]: タクソノミー外のタグです: %s" % [index, tag_id]
				)
	if typeof(raw["target"]) not in [TYPE_STRING, TYPE_NIL]:
		result.errors.append("target: 文字列またはnullである必要があります。")
	if not result.errors.is_empty():
		return result

	var normalized: Dictionary = raw.duplicate(true)
	var normalized_tags: Array[String] = []
	var all_tags: Array = raw["skill_tags"]
	for index: int in range(mini(2, all_tags.size())):
		normalized_tags.append(String(all_tags[index]))
	normalized["skill_tags"] = normalized_tags
	if String(normalized["action_type"]) == "other":
		normalized["needs_roll"] = false
	if String(normalized["action_type"]) == "attack":
		# 軽量戦闘は必ずPCの判定結果を入力に解決する。AIが判定を省略できないよう固定する。
		normalized["needs_roll"] = true
	result.intent = normalized

	var target_value: Variant = normalized["target"]
	var target_is_allowed: bool = target_value == null or allowed_targets.has(target_value)
	var action_type: String = normalized["action_type"]
	# §6.2 / INV-3: targetは動的enumへの所属とaction_type別prefixをコード側で再検証する。
	# summary_jaやtrigger_hintなどの自由文から不足targetを補うことはしない。
	if TARGET_REQUIRED_ACTIONS.has(action_type) and (
		target_value == null
		or not target_is_allowed
		or not _target_matches_action_type(action_type, target_value)
	):
		result.errors.append("%s: 許可されたtargetが必要です。" % action_type)
		result.failure_kind = FAILURE_REQUIRED_TARGET
		return result
	if action_type == "check" and (
		not target_is_allowed
		or (
			target_value != null
			and not _target_matches_action_type(action_type, target_value)
		)
	):
		result.errors.append("check: targetが現在シーンの許可値にありません。")
		result.failure_kind = FAILURE_CHECK_TARGET
		return result
	if not target_is_allowed:
		result.errors.append("target: 現在ターンの許可値にありません。")
		return result
	if action_type == "attack" and not ATTACK_ABILITIES.has(String(normalized["ability"])):
		result.errors.append("attack: abilityはSTRまたはDEXである必要があります。")
		return result
	return result


func _result_from_intent(intent: Dictionary, allowed_targets: Array[Variant]) -> Result:
	var result: Result = Result.new()
	result.action_type = String(intent["action_type"])
	result.ability_id = String(intent["ability"])
	var tags: Array = intent["skill_tags"]
	for tag_value: Variant in tags:
		result.skill_tags.append(String(tag_value))
	result.target = intent["target"]
	result.difficulty = String(intent["difficulty"])
	result.difficulty_mod = _difficulty_modifier(result.difficulty)
	result.needs_roll = bool(intent["needs_roll"])
	result.summary_ja = String(intent["summary_ja"])
	result.allowed_targets = allowed_targets.duplicate(true)
	result.request = _build_request(
		result.ability_id,
		result.skill_tags,
		result.difficulty_mod,
	)
	return result


func _fallback_result(
	allowed_targets: Array[Variant],
	errors: Array[String],
	path: Array[String],
	retry_count: int = 0,
) -> Result:
	var result: Result = Result.new()
	result.allowed_targets = allowed_targets.duplicate(true)
	result.executable = false
	result.no_state_change = false
	result.confirmation_response = tr("もう少し具体的に何をするか教えてください。")
	result.validation_retry_count = retry_count
	result.validation_errors = errors.duplicate()
	result.audit_path = path.duplicate()
	result.request = _build_request("STR", [], 0)
	return result


func _build_request(
	ability_id: String,
	skill_tags: Array[String],
	difficulty_mod: int,
) -> Judgment.Request:
	var request: Judgment.Request = Judgment.Request.new()
	request.ability = _ability_from_id(ability_id)
	request.skill_tags = skill_tags.duplicate()
	request.situation_mod = clampi(difficulty_mod, -1, 1)
	return request


func _build_runtime_constraints(allowed_targets: Array[Variant]) -> RuntimeConstraints:
	var result: RuntimeConstraints = RuntimeConstraints.new()
	var grammar_template: String = _read_text(GRAMMAR_PATH, result.errors)
	var schema_text: String = _read_text(SCHEMA_PATH, result.errors)
	if not result.errors.is_empty():
		return result
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(schema_text)
	if parse_error != OK or typeof(json.data) != TYPE_DICTIONARY:
		result.errors.append("意図分類JSONスキーマを解析できません。")
		return result
	var schema: Dictionary = json.data
	var properties_value: Variant = schema.get("properties")
	if typeof(properties_value) != TYPE_DICTIONARY:
		result.errors.append("意図分類JSONスキーマにpropertiesがありません。")
		return result
	var properties: Dictionary = properties_value
	var target_value: Variant = properties.get("target")
	if typeof(target_value) != TYPE_DICTIONARY:
		result.errors.append("意図分類JSONスキーマにtarget定義がありません。")
		return result
	var target_schema: Dictionary = target_value
	var schema_enum_value: Variant = target_schema.get("enum")
	if typeof(schema_enum_value) != TYPE_ARRAY:
		result.errors.append("意図分類JSONスキーマのtarget.enumが配列ではありません。")
		return result
	var schema_enum: Array = schema_enum_value
	if not schema_enum.has(TARGET_ENUM_PLACEHOLDER):
		result.errors.append("意図分類JSONスキーマにtarget番兵値がありません。")
		return result
	target_schema["enum"] = allowed_targets.duplicate(true)
	properties["target"] = target_schema
	schema["properties"] = properties
	result.schema = schema

	var string_targets: Array[String] = []
	for target: Variant in allowed_targets:
		if typeof(target) == TYPE_STRING:
			string_targets.append(String(target))
	var choices: Array[String] = []
	for target_id: String in string_targets:
		choices.append(_gbnf_literal(JSON.stringify(target_id)))
	var runtime_grammar: String = grammar_template
	var placeholder_rule: String = (
		"target-enum ::= " + _gbnf_literal(JSON.stringify(TARGET_ENUM_PLACEHOLDER))
	)
	# §6.2 / INV-3: 静的GBNFの番兵ルールが厳密に存在する場合だけ動的enumへ置換する。
	# コメント内の番兵文字列は検査・置換対象にせず、生成物の説明をそのまま保つ。
	if not _has_non_comment_line(grammar_template, placeholder_rule):
		result.errors.append("GBNFにtarget番兵ルールがありません。")
		return result
	if choices.is_empty():
		if not _has_non_comment_line(
			grammar_template,
			"target ::= target-enum | \"null\"",
		):
			result.errors.append("GBNFにtargetルールがありません。")
			return result
		runtime_grammar = _replace_non_comment_line(
			runtime_grammar,
			"target ::= target-enum | \"null\"",
			"target ::= \"null\"",
		)
		runtime_grammar = _replace_non_comment_line(
			runtime_grammar,
			placeholder_rule,
			"target-enum ::= \"\\\"__NO_STRING_TARGETS__\\\"\"",
		)
	else:
		runtime_grammar = _replace_non_comment_line(
			runtime_grammar,
			placeholder_rule,
			"target-enum ::= %s" % " | ".join(choices),
		)
	if _non_comment_contains(runtime_grammar, TARGET_ENUM_PLACEHOLDER):
		result.errors.append("GBNFのtarget番兵値を置換できませんでした。")
		return result
	result.grammar = runtime_grammar
	return result


func _build_character_skills(state: GameState, taxonomy: Taxonomy) -> String:
	var owned: Array[String] = []
	for skill_id: String in state.character.skills:
		_append_unique(owned, skill_id)
	for specialty: Dictionary in state.character.specialties:
		var tags_value: Variant = specialty.get("tags", [])
		if typeof(tags_value) != TYPE_ARRAY:
			continue
		var tags: Array = tags_value
		for tag_value: Variant in tags:
			if typeof(tag_value) == TYPE_STRING:
				_append_unique(owned, String(tag_value))
	var lines: Array[String] = []
	for tag_id: String in owned:
		lines.append("- %s: %s" % [tag_id, taxonomy.hints.get(tag_id, "")])
	return "\n".join(lines)


func _build_taxonomy_entries(taxonomy: Taxonomy) -> String:
	var lines: Array[String] = []
	for tag_id: String in taxonomy.ids:
		lines.append("- %s: %s" % [tag_id, taxonomy.hints.get(tag_id, "")])
	return "\n".join(lines)


func _build_check_hints(state: GameState, scenario: Scenario) -> String:
	var scene: Dictionary = _find_current_scene(state, scenario)
	var checks_value: Variant = scene.get("checks", [])
	if typeof(checks_value) != TYPE_ARRAY:
		return ""
	var lines: Array[String] = []
	var checks: Array = checks_value
	for check_value: Variant in checks:
		if typeof(check_value) != TYPE_DICTIONARY:
			continue
		var check: Dictionary = check_value
		if typeof(check.get("id")) != TYPE_STRING:
			continue
		if typeof(check.get("trigger_hint")) != TYPE_STRING:
			continue
		lines.append(
			"- check:%s: %s"
			% [String(check["id"]), String(check["trigger_hint"])]
		)
	return "\n".join(lines)


func _load_taxonomy() -> Taxonomy:
	var result: Taxonomy = Taxonomy.new()
	var source: String = _read_text(TAXONOMY_PATH, result.errors)
	if not result.errors.is_empty():
		return result
	var json: JSON = JSON.new()
	if json.parse(source) != OK or typeof(json.data) != TYPE_ARRAY:
		result.errors.append("スキルタグタクソノミーを解析できません。")
		return result
	var entries: Array = json.data
	for index: int in range(entries.size()):
		var entry_value: Variant = entries[index]
		if typeof(entry_value) != TYPE_DICTIONARY:
			result.errors.append("skill_tags[%d]がJSONオブジェクトではありません。" % index)
			continue
		var entry: Dictionary = entry_value
		if typeof(entry.get("id")) != TYPE_STRING:
			result.errors.append("skill_tags[%d].idが文字列ではありません。" % index)
			continue
		if typeof(entry.get("hint_ja")) != TYPE_STRING:
			result.errors.append("skill_tags[%d].hint_jaが文字列ではありません。" % index)
			continue
		var tag_id: String = entry["id"]
		result.ids[tag_id] = true
		result.hints[tag_id] = String(entry["hint_ja"])
	return result


func _render_prompt(template: String, values: Dictionary[String, String]) -> String:
	# 挿入値を再走査しない1パス置換により、入力中の{{placeholder}}を展開しない（ARCH-9）。
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


func _find_current_scene(state: GameState, scenario: Scenario) -> Dictionary:
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


func _validate_string_enum(
	data: Dictionary,
	field_name: String,
	allowed: Array[String],
	errors: Array[String],
) -> void:
	if typeof(data[field_name]) != TYPE_STRING:
		errors.append("%s: 文字列である必要があります。" % field_name)
		return
	var value: String = data[field_name]
	if not allowed.has(value):
		errors.append("%s: enumにない値です: %s" % [field_name, value])


func _difficulty_modifier(difficulty: String) -> int:
	match difficulty:
		"easy":
			return 1
		"hard":
			return -1
		_:
			return 0


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


func _target_matches_action_type(action_type: String, target: Variant) -> bool:
	if typeof(target) != TYPE_STRING:
		return false
	var target_id: String = target
	match action_type:
		"move":
			return target_id.begins_with("exit:")
		"item":
			return target_id.begins_with("item:")
		"talk":
			return target_id.begins_with("npc:")
		"attack":
			return target_id.begins_with("enemy:")
		"check":
			return target_id.begins_with("check:")
		_:
			return true


func _append_target(
	targets: Array[Variant],
	seen: Dictionary[String, bool],
	prefix: String,
	value: Variant,
) -> void:
	if typeof(value) != TYPE_STRING:
		return
	var raw_id: String = value
	if raw_id.is_empty():
		return
	var target_id: String = prefix + raw_id
	if seen.has(target_id):
		return
	seen[target_id] = true
	targets.append(target_id)


func _append_unique(values: Array[String], value: String) -> void:
	if not value.is_empty() and not values.has(value):
		values.append(value)


func _has_non_comment_line(text: String, expected_line: String) -> bool:
	for line: String in text.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if stripped == expected_line:
			return true
	return false


func _non_comment_contains(text: String, fragment: String) -> bool:
	for line: String in text.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if stripped.contains(fragment):
			return true
	return false


func _replace_non_comment_line(
	text: String,
	expected_line: String,
	replacement_line: String,
) -> String:
	var lines: PackedStringArray = text.split("\n", true)
	for index: int in range(lines.size()):
		var stripped: String = lines[index].strip_edges()
		if stripped.begins_with("#"):
			continue
		if stripped == expected_line:
			lines[index] = replacement_line
	return "\n".join(lines)


func _gbnf_literal(value: String) -> String:
	var escaped: String = value.replace("\\", "\\\\")
	escaped = escaped.replace("\"", "\\\"")
	escaped = escaped.replace("\r", "\\r")
	escaped = escaped.replace("\n", "\\n")
	escaped = escaped.replace("\t", "\\t")
	return "\"%s\"" % escaped


func _on_generation_finished(full_text: String) -> void:
	if _waiting_for_generation:
		_generation_settled.emit(full_text, false)


func _on_generation_failed(_error: Variant) -> void:
	if _waiting_for_generation:
		_generation_settled.emit("", true)
