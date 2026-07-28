extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"

var _backend: BackendMock
var _classifier: IntentClassifier


class SynchronousFailureBackend:
	extends LLMBackend

	var generate_count: int = 0


	func generate(_prompt: String, _opts: GenOpts) -> void:
		generate_count += 1
		generation_failed.emit(
			LLMError.new("synchronous_failure", "同期失敗テスト")
		)


func before_each() -> void:
	_backend = BackendMock.new()
	_classifier = IntentClassifier.new(_backend)


func test_01_valid_json_is_converted_to_judgment_request() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"WIS",
				["skill.perception"],
				"check:check_find_path",
				"normal",
				true,
				"安全な道を探す",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("安全な道を探す")

	assert_true(result.executable)
	assert_eq(result.action_type, "check")
	assert_eq(result.target, "check:check_find_path")
	assert_eq(result.summary_ja, "安全な道を探す")
	assert_not_null(result.request)
	assert_eq(result.request.ability, Types.Ability.WIS)
	assert_eq(result.request.skill_tags, ["skill.perception"])
	assert_eq(result.request.situation_mod, 0)
	assert_eq(_classifier.prompt_history.size(), 1)
	var opts: LLMBackend.GenOpts = _classifier.options_history[0]
	assert_eq(opts.temperature, 0.1)
	assert_false(opts.grammar.is_empty())
	assert_false(opts.json_schema.is_empty())
	assert_true(
		_classifier.prompt_history[0].contains(
			"- skill.stealth: 身を隠す、気配を消す、見つからずに移動する行動"
		)
	)


func test_02_unknown_skill_tag_retries_once_then_succeeds() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"DEX",
				["skill.not_in_taxonomy"],
				null,
				"normal",
				true,
				"慎重に進む",
			),
			_intent_json(
				"check",
				"DEX",
				["skill.stealth"],
				null,
				"normal",
				true,
				"慎重に進む",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("慎重に進む")

	assert_true(result.executable)
	assert_eq(result.skill_tags, ["skill.stealth"])
	assert_eq(result.validation_retry_count, 1)
	assert_eq(_classifier.prompt_history.size(), 2)
	assert_true(result.audit_path.has("validation_retry"))


func test_03_two_validation_failures_fall_back_to_safe_other() -> void:
	_backend.set_responses(
		[
			_intent_json("teleport", "WIS", [], null, "normal", false, "瞬間移動する"),
			_intent_json("check", "LUCK", [], null, "normal", true, "運を試す"),
		]
	)

	var result: IntentClassifier.Result = await _classify("瞬間移動する")

	assert_eq(result.action_type, "other")
	assert_false(result.needs_roll)
	assert_false(result.executable)
	assert_false(result.no_state_change)
	assert_false(result.confirmation_response.is_empty())
	assert_eq(result.validation_retry_count, 1)
	assert_eq(_classifier.prompt_history.size(), 2)
	assert_eq(result.audit_path[-1], "fallback_other")


func test_04_hard_difficulty_becomes_minus_one_modifier() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"STR",
				["skill.athletics"],
				null,
				"hard",
				true,
				"岩を持ち上げる",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("岩を持ち上げる")

	assert_eq(result.difficulty, "hard")
	assert_eq(result.difficulty_mod, -1)
	assert_eq(result.request.situation_mod, -1)


func test_05_broken_json_twice_does_not_crash_and_uses_fallback() -> void:
	_backend.set_responses(["{not json", "{\"action_type\":"])

	var result: IntentClassifier.Result = await _classify("何かする")

	assert_eq(result.action_type, "other")
	assert_false(result.needs_roll)
	assert_false(result.executable)
	assert_eq(result.validation_retry_count, 1)
	assert_eq(_classifier.prompt_history.size(), 2)
	assert_true(_contains_fragment(result.validation_errors, "JSONの解析に失敗"))


func test_06_three_or_more_skill_tags_are_truncated_to_first_two() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"DEX",
				["skill.stealth", "body.acrobatics", "skill.athletics"],
				null,
				"easy",
				true,
				"身軽に忍び込む",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("身軽に忍び込む")

	assert_eq(result.skill_tags, ["skill.stealth", "body.acrobatics"])
	assert_eq(result.request.skill_tags, ["skill.stealth", "body.acrobatics"])
	assert_eq(_classifier.prompt_history.size(), 1)


func test_07_move_without_valid_target_retries_then_becomes_unavailable() -> void:
	_backend.set_responses(
		[
			_intent_json("move", "DEX", [], null, "normal", false, "奥へ進む"),
			_intent_json(
				"move",
				"DEX",
				[],
				"exit:not_in_current_scene",
				"normal",
				false,
				"奥へ進む",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("奥へ進む")

	assert_eq(result.action_type, "move")
	assert_false(result.executable)
	assert_false(result.no_state_change)
	assert_null(result.target)
	assert_false(result.confirmation_response.is_empty())
	assert_eq(result.validation_retry_count, 1)
	assert_eq(result.audit_path[-1], "required_target_unavailable")


func test_08_target_enum_is_composed_from_current_game_state() -> void:
	var state: GameState = _state()
	state.character.inventory = [
		{"item_id": "torch", "count": 1},
		{"item_id": "potion", "count": 2},
		{"item_id": "empty", "count": 0},
	]
	state.active_enemies = [
		{"enemy_id": "goblin", "hp": {"current": 4, "max": 4}},
	]
	_backend.set_responses(
		[
			_intent_json(
				"talk",
				"CHA",
				["skill.persuasion"],
				"npc:guide",
				"normal",
				false,
				"案内人に話しかける",
			),
		]
	)

	var result: IntentClassifier.Result = await _classifier.classify(
		"案内人に話しかける",
		"洞窟の入口",
		state,
		_fixture(),
	)
	var expected: Array[Variant] = [
		"exit:depths",
		"item:torch",
		"item:potion",
		"npc:guide",
		"enemy:goblin",
		"check:check_find_path",
		null,
	]

	assert_eq(result.allowed_targets, expected)
	var opts: LLMBackend.GenOpts = _classifier.options_history[0]
	var properties: Dictionary = opts.json_schema["properties"]
	var target_schema: Dictionary = properties["target"]
	assert_eq(target_schema["enum"], expected)
	for target: Variant in expected:
		if typeof(target) == TYPE_STRING:
			assert_true(opts.grammar.contains(String(target)))
	assert_false(_grammar_code_contains(opts.grammar, "__TARGET_ENUM_RUNTIME__"))
	assert_true(
		opts.grammar.contains("# 未置換の番兵値 __TARGET_ENUM_RUNTIME__ を分類に使用してはいけません。")
	)
	assert_true(_classifier.prompt_history[0].contains("check:check_find_path: 安全な道を探す"))


func test_09_other_with_state_verb_reclassifies_once_then_requests_confirmation() -> void:
	_backend.set_responses(
		[
			_intent_json("other", "WIS", [], null, "normal", false, "松明を拾う"),
			_intent_json("other", "WIS", [], null, "normal", false, "松明を拾う"),
		]
	)

	var result: IntentClassifier.Result = await _classify("松明を拾う")

	assert_eq(result.action_type, "other")
	assert_false(result.executable)
	assert_false(result.no_state_change)
	assert_eq(result.other_reclassification_count, 1)
	assert_true(result.detected_state_verbs.has("拾う"))
	assert_eq(_classifier.prompt_history.size(), 2)
	assert_ne(_classifier.prompt_history[1], _classifier.prompt_history[0])
	assert_true(
		_classifier.prompt_history[1].contains(
			"状態変更語彙による再分類ヒント（空なら状態変更語彙の検出なし）:\n拾う\n"
		)
	)
	assert_false(result.confirmation_response.is_empty())
	assert_eq(result.audit_path[-1], "other_execution_unavailable")


func test_10_unknown_check_target_retries_then_becomes_free_check() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"WIS",
				["skill.perception"],
				"check:unknown_first",
				"normal",
				true,
				"天井を調べる",
			),
			_intent_json(
				"check",
				"WIS",
				["skill.perception"],
				"check:unknown_second",
				"normal",
				true,
				"天井を調べる",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("天井を調べる")

	assert_true(result.executable)
	assert_eq(result.action_type, "check")
	assert_true(result.needs_roll)
	assert_null(result.target)
	assert_not_null(result.request)
	assert_eq(result.validation_retry_count, 1)
	assert_eq(result.audit_path[-1], "free_check_confirmed")


func test_11_other_without_state_verb_confirms_no_state_change_in_one_generation() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"other",
				"WIS",
				["skill.perception"],
				null,
				"normal",
				false,
				"周囲を見回す",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("周囲を見回す")

	assert_true(result.executable)
	assert_true(result.no_state_change)
	assert_eq(result.action_type, "other")
	assert_eq(result.other_reclassification_count, 0)
	assert_true(result.detected_state_verbs.is_empty())
	assert_eq(_classifier.prompt_history.size(), 1)
	assert_eq(result.audit_path[-1], "other_no_state_change")


func test_12_attack_with_wis_retries_once_then_falls_back() -> void:
	var state: GameState = _state()
	state.active_enemies = [
		{"enemy_id": "goblin", "hp": {"current": 4, "max": 4}},
	]
	_backend.set_responses(
		[
			_intent_json(
				"attack",
				"WIS",
				["skill.tactics"],
				"enemy:goblin",
				"normal",
				true,
				"ゴブリンを攻撃する",
			),
			_intent_json(
				"attack",
				"WIS",
				["skill.tactics"],
				"enemy:goblin",
				"normal",
				true,
				"ゴブリンを攻撃する",
			),
		]
	)

	var result: IntentClassifier.Result = await _classifier.classify(
		"ゴブリンを攻撃する",
		"洞窟の入口",
		state,
		_fixture(),
	)

	assert_eq(result.action_type, "other")
	assert_false(result.needs_roll)
	assert_false(result.executable)
	assert_eq(result.validation_retry_count, 1)
	assert_eq(_classifier.prompt_history.size(), 2)
	assert_true(_contains_fragment(result.validation_errors, "STRまたはDEX"))


func test_13_check_target_retry_with_broken_json_still_becomes_free_check() -> void:
	_backend.set_responses(
		[
			_intent_json(
				"check",
				"WIS",
				["skill.perception"],
				"check:not_in_current_scene",
				"normal",
				true,
				"天井を調べる",
			),
			"{broken json",
		]
	)

	var result: IntentClassifier.Result = await _classify("天井を調べる")

	assert_true(result.executable)
	assert_eq(result.action_type, "check")
	assert_true(result.needs_roll)
	assert_null(result.target)
	assert_eq(result.validation_retry_count, 1)
	assert_true(_contains_fragment(result.validation_errors, "JSONの解析に失敗"))
	assert_eq(result.audit_path[-1], "free_check_confirmed")


func test_14_player_input_placeholders_are_not_expanded() -> void:
	_backend.constrained_output_supported = false
	_backend.set_responses(
		[
			_intent_json(
				"other",
				"WIS",
				[],
				null,
				"normal",
				false,
				"記号を読み上げる",
			),
		]
	)

	var result: IntentClassifier.Result = await _classify("{{allowed_targets}}と読み上げる")

	assert_true(result.executable)
	assert_true(result.no_state_change)
	assert_true(
		_classifier.prompt_history[0].contains(
			"分類対象のプレイヤー入力:\n{{allowed_targets}}と読み上げる\n"
		)
	)
	var opts: LLMBackend.GenOpts = _classifier.options_history[0]
	assert_true(opts.grammar.is_empty())
	assert_true(opts.json_schema.is_empty())
	assert_true(_classifier.prompt_history[0].contains("- skill.perception: 周囲を調べ"))


func test_15_synchronous_backend_failure_does_not_miss_signal() -> void:
	var backend: SynchronousFailureBackend = SynchronousFailureBackend.new()
	var classifier: IntentClassifier = IntentClassifier.new(backend)

	var result: IntentClassifier.Result = await classifier.classify(
		"周囲を見る",
		"洞窟の入口",
		_state(),
		_fixture(),
	)

	assert_eq(backend.generate_count, 2)
	assert_eq(result.action_type, "other")
	assert_false(result.executable)
	assert_eq(result.validation_retry_count, 1)
	assert_true(_contains_fragment(result.validation_errors, "バックエンドの生成に失敗"))


func _classify(player_input: String) -> IntentClassifier.Result:
	return await _classifier.classify(
		player_input,
		"洞窟の入口で案内人と奥へ続く道が見える。",
		_state(),
		_fixture(),
	)


func _fixture() -> Scenario:
	var load_result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(
		load_result.is_success(),
		"フィクスチャをロードできません: %s" % str(load_result.errors),
	)
	return load_result.scenario


func _state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	return state


func _intent_json(
	action_type: String,
	ability: String,
	skill_tags: Array[String],
	target: Variant,
	difficulty: String,
	needs_roll: bool,
	summary_ja: String,
) -> String:
	return JSON.stringify(
		{
			"action_type": action_type,
			"ability": ability,
			"skill_tags": skill_tags,
			"target": target,
			"difficulty": difficulty,
			"needs_roll": needs_roll,
			"summary_ja": summary_ja,
		}
	)


func _contains_fragment(messages: Array[String], fragment: String) -> bool:
	for message: String in messages:
		if message.contains(fragment):
			return true
	return false


func _grammar_code_contains(grammar: String, fragment: String) -> bool:
	for line: String in grammar.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("#"):
			continue
		if stripped.contains(fragment):
			return true
	return false
