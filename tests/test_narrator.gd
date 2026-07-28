extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"
const NARRATOR_SOURCE_PATH: String = "res://game/ai/narrator.gd"
const SYSTEM_PROMPT_PATH: String = "res://prompts/ja/system_gm.txt"
const NARRATE_PROMPT_PATH: String = "res://prompts/ja/narrate.txt"

var _backend: BackendMock
var _narrator: Narrator
var _streamed_text: String
var _finished_text: String
var _failed_count: int


class SynchronousNarrationBackend:
	extends LLMBackend


	func generate(_prompt: String, _opts: GenOpts) -> void:
		token_streamed.emit("同期")
		generation_finished.emit("同期描写")


func before_each() -> void:
	_backend = BackendMock.new()
	_narrator = Narrator.new(_backend)
	_streamed_text = ""
	_finished_text = ""
	_failed_count = 0
	_narrator.token_streamed.connect(_on_token_streamed)
	_narrator.generation_finished.connect(_on_generation_finished)
	_narrator.generation_failed.connect(_on_generation_failed)


func test_01_prompt_sections_follow_specified_order() -> void:
	var state: GameState = _state()
	state.character.name = "順序確認キャラクター"
	var prompt_result: Narrator.PromptBuildResult = _narrator.build_prompt(
		state,
		_fixture(),
		"順序確認サマリー",
		["順序確認ログ"],
		{
			"tier": "SUCCESS",
			"action_summary": "順序確認行動",
			"complication": "",
		},
	)

	assert_true(prompt_result.errors.is_empty())
	var prompt: String = prompt_result.prompt
	var system_position: int = prompt.find("あなたは一人用TRPGのゲームマスターです。")
	var character_position: int = prompt.find("順序確認キャラクター")
	var scene_position: int = prompt.find("洞窟の奥へ進む")
	var summary_position: int = prompt.find("順序確認サマリー")
	var log_position: int = prompt.find("順序確認ログ")
	var result_position: int = prompt.find("順序確認行動")

	assert_gte(system_position, 0)
	assert_gt(character_position, system_position)
	assert_gt(scene_position, character_position)
	assert_gt(summary_position, scene_position)
	assert_gt(log_position, summary_position)
	assert_gt(result_position, log_position)


func test_02_confirmed_tier_and_complication_are_fixed_information() -> void:
	var long_applied_effect: String = "低優先の適用情報".repeat(40)
	var prompt_result: Narrator.PromptBuildResult = _narrator.build_prompt(
		_state(),
		_fixture(),
		"既存の経緯",
		["松明を掲げて進んだ。"],
		{
			"tier": Types.ResultTier.PARTIAL,
			"summary_ja": "崩れかけた橋を渡る",
			"complication_id": "torch_lost",
			"applied_effects": [long_applied_effect],
		},
	)
	var prompt: String = prompt_result.prompt
	var confirmed_value: Variant = JSON.parse_string(
		_section_after_heading(prompt, "【今回の確定情報】")
	)
	var confirmed: Dictionary = confirmed_value if typeof(confirmed_value) == TYPE_DICTIONARY else {}

	assert_true(prompt_result.errors.is_empty())
	assert_true(prompt.contains("【今回の確定情報】"))
	assert_true(prompt.contains("- HP、所持品、経験点、フラグ、シーン進行などの状態変更を新たに宣言しない。"))
	assert_true(prompt.contains("すでに確定・適用・保存されています"))
	assert_eq(confirmed.get("tier", ""), "PARTIAL")
	assert_eq(confirmed.get("action_summary", ""), "崩れかけた橋を渡る")
	assert_eq(confirmed.get("complication", ""), "torch_lost")
	assert_false(confirmed.has("applied_effects"))


func test_03_streaming_is_relayed_and_generation_finishes() -> void:
	_backend.token_size = 2
	_backend.set_responses(["洞窟の奥から冷たい風が吹く。"])

	var result: Narrator.GenerationResult = await _narrator.narrate(
		_state(),
		_fixture(),
		"",
		["あなたは入口に立った。"],
		{
			"tier": "SUCCESS",
			"action_summary": "奥の気配を探る",
			"complication": "",
		},
	)

	assert_false(result.failed)
	assert_eq(result.text, "洞窟の奥から冷たい風が吹く。")
	assert_eq(_streamed_text, result.text)
	assert_eq(_finished_text, result.text)
	assert_eq(_failed_count, 0)
	assert_eq(_narrator.prompt_history.size(), 1)
	var opts: LLMBackend.GenOpts = _narrator.options_history[0]
	assert_eq(opts.max_tokens, 400)
	assert_true(opts.grammar.is_empty())
	assert_true(opts.json_schema.is_empty())


func test_04_only_latest_six_turns_are_included_without_mutating_state() -> void:
	var logs: Array[String] = [
		"古いログ0",
		"ログ1",
		"ログ2",
		"ログ3",
		"ログ4",
		"ログ5",
		"最新ログ6",
	]
	var state: GameState = _state()
	var before: String = JSON.stringify(state.serialize())
	_backend.set_responses(["六ターン分を踏まえた描写。"])

	var result: Narrator.GenerationResult = await _narrator.narrate(
		state,
		_fixture(),
		"",
		logs,
		{"tier": "SUCCESS", "action_summary": "確認する", "complication": ""},
	)

	assert_false(result.failed)
	assert_false(result.prompt.contains("古いログ0"))
	for index: int in range(1, 7):
		assert_true(result.prompt.contains("ログ%d" % index))
	assert_eq(JSON.stringify(state.serialize()), before)


func test_05_synchronous_backend_signals_are_not_missed() -> void:
	var backend: SynchronousNarrationBackend = SynchronousNarrationBackend.new()
	var narrator: Narrator = Narrator.new(backend)
	var streamed: Array[String] = []
	narrator.token_streamed.connect(func(text: String) -> void: streamed.append(text))

	var result: Narrator.GenerationResult = await narrator.narrate(
		_state(),
		_fixture(),
		"",
		[],
		{"tier": "SUCCESS", "action_summary": "同期確認", "complication": ""},
	)

	assert_false(result.failed)
	assert_eq(result.text, "同期描写")
	assert_eq(streamed, ["同期"])


func test_06_prompt_templates_are_loaded_from_files() -> void:
	var source: String = _read_text(NARRATOR_SOURCE_PATH)
	var system_template: String = _read_text(SYSTEM_PROMPT_PATH)
	var narrate_template: String = _read_text(NARRATE_PROMPT_PATH)
	var characteristic_lines: Array[String] = [
		"コードが確定した事実を、日本語の臨場感ある短い場面描写にしてください。",
		"- HP、所持品、経験点、フラグ、シーン進行などの状態変更を新たに宣言しない。",
		"今回の確定情報はコード側ですでに確定・適用・保存されています。その内容を変えず、上の順序で与えられた文脈に沿って場面を描写してください。",
	]

	assert_true(source.contains(SYSTEM_PROMPT_PATH))
	assert_true(source.contains(NARRATE_PROMPT_PATH))
	for line: String in characteristic_lines:
		assert_false(source.contains(line), "テンプレートの特徴的な行がソースに直書きされています。")
	assert_true(system_template.contains("禁止事項:"))
	assert_true(narrate_template.contains("{{system_prompt}}"))
	assert_true(narrate_template.contains("{{confirmed_result}}"))


func test_07_budget_keeps_required_json_fields_and_latest_logs() -> void:
	var state: GameState = _state()
	state.character.description = "予算で落とす説明".repeat(80)
	state.character.inventory = [
		{"item_id": "予算で落とす所持品".repeat(30), "count": 1},
	]
	state.character.specialties = [
		{"label": "必須専門分野", "tags": ["skill.perception"]},
	]
	state.character.xp = 77
	var logs: Array[String] = [
		"最大六ターンの範囲外",
		"予算で落ちる古いターン" + "古".repeat(1200),
		"残る新しいターン2",
		"残る新しいターン3",
		"残る新しいターン4",
		"残る新しいターン5",
		"最優先で残る最新ターン6",
	]
	var prompt_result: Narrator.PromptBuildResult = _narrator.build_prompt(
		state,
		_fixture(),
		"長いローリングサマリー".repeat(80),
		logs,
		{
			"tier": "SUCCESS",
			"action_summary": "必須の行動要約",
			"complication": "必須の代償",
			"applied_effects": ["予算で落とす確定結果の追加情報".repeat(40)],
		},
	)
	var character_value: Variant = JSON.parse_string(
		_section_after_heading(prompt_result.prompt, "【キャラクターシート要約】")
	)
	var character_summary: Dictionary = (
		character_value if typeof(character_value) == TYPE_DICTIONARY else {}
	)
	var confirmed_value: Variant = JSON.parse_string(
		_section_after_heading(prompt_result.prompt, "【今回の確定情報】")
	)
	var confirmed: Dictionary = confirmed_value if typeof(confirmed_value) == TYPE_DICTIONARY else {}

	assert_true(prompt_result.errors.is_empty())
	assert_eq(character_summary.get("specialties", []), state.character.specialties)
	assert_eq(int(character_summary.get("xp", -1)), 77)
	assert_false(character_summary.has("description"))
	assert_eq(confirmed.get("tier", ""), "SUCCESS")
	assert_eq(confirmed.get("action_summary", ""), "必須の行動要約")
	assert_eq(confirmed.get("complication", ""), "必須の代償")
	assert_false(confirmed.has("applied_effects"))
	assert_false(prompt_result.prompt.contains("最大六ターンの範囲外"))
	assert_false(prompt_result.prompt.contains("予算で落ちる古いターン"))
	for index: int in range(2, 6):
		assert_true(prompt_result.prompt.contains("残る新しいターン%d" % index))
	assert_true(prompt_result.prompt.contains("最優先で残る最新ターン6"))


func test_08_judgment_result_is_normalized_through_dictionary_path() -> void:
	var judgment_result: Judgment.Result = Judgment.Result.new()
	judgment_result.dice = [5, 4]
	judgment_result.kept = [5, 4]
	judgment_result.natural = 9
	judgment_result.total = 11
	judgment_result.tier = Types.ResultTier.PARTIAL
	judgment_result.applied_tag = "skill.perception"

	var prompt_result: Narrator.PromptBuildResult = _narrator.build_prompt(
		_state(),
		_fixture(),
		"",
		[],
		judgment_result,
	)
	var confirmed_value: Variant = JSON.parse_string(
		_section_after_heading(prompt_result.prompt, "【今回の確定情報】")
	)
	var confirmed: Dictionary = confirmed_value if typeof(confirmed_value) == TYPE_DICTIONARY else {}

	assert_true(prompt_result.errors.is_empty())
	assert_eq(int(confirmed.get("natural", -1)), 9)
	assert_eq(int(confirmed.get("total", -1)), 11)
	assert_eq(confirmed.get("tier", ""), "PARTIAL")
	assert_eq(confirmed.get("applied_tag", ""), "skill.perception")


func _state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	state.turn_count = 7
	state.character.name = "探索者"
	state.character.description = "古い遺跡を調べる旅人"
	state.character.skills = ["skill.perception"]
	state.character.inventory = [{"item_id": "torch", "count": 1}]
	return state


func _fixture() -> Scenario:
	var load_result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(
		load_result.is_success(),
		"フィクスチャをロードできません: %s" % str(load_result.errors),
	)
	return load_result.scenario


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_not_null(file, "ファイルを開けません: %s" % path)
	if file == null:
		return ""
	return file.get_as_text()


func _section_after_heading(prompt: String, heading: String) -> String:
	var heading_position: int = prompt.find(heading)
	if heading_position < 0:
		return ""
	var content_start: int = prompt.find("\n", heading_position)
	if content_start < 0:
		return ""
	content_start += 1
	var content_end: int = prompt.find("\n\n", content_start)
	if content_end < 0:
		content_end = prompt.length()
	return prompt.substr(content_start, content_end - content_start).strip_edges()


func _on_token_streamed(text: String) -> void:
	_streamed_text += text


func _on_generation_finished(full_text: String) -> void:
	_finished_text = full_text


func _on_generation_failed(_error: Variant) -> void:
	_failed_count += 1
