extends GutTest

const SUMMARIZER_SOURCE_PATH: String = "res://game/ai/summarizer.gd"
const SUMMARIZE_PROMPT_PATH: String = "res://prompts/ja/summarize.txt"

var _backend: BackendMock
var _summarizer: Summarizer


func before_each() -> void:
	_backend = BackendMock.new()
	_summarizer = Summarizer.new(_backend)


func test_01_oldest_two_turns_are_folded_when_log_exceeds_six() -> void:
	var logs: Array[String] = _logs(7)
	_backend.set_responses(["既存の経緯に最初の二ターンを統合した。"])

	var result: Summarizer.SummaryResult = await _summarizer.summarize(
		_state(),
		"既存サマリー固有語",
		logs,
	)

	assert_true(result.triggered)
	assert_false(result.failed)
	assert_eq(result.folded_logs, ["ターン0固有語", "ターン1固有語"])
	assert_eq(
		result.remaining_logs,
		[
			"ターン2固有語",
			"ターン3固有語",
			"ターン4固有語",
			"ターン5固有語",
			"ターン6固有語",
		],
	)
	assert_eq(result.summary, "既存の経緯に最初の二ターンを統合した。")
	assert_true(result.prompt.contains("既存サマリー固有語"))
	assert_true(result.prompt.contains("ターン0固有語"))
	assert_true(result.prompt.contains("ターン1固有語"))
	assert_false(result.prompt.contains("ターン2固有語"))
	var opts: LLMBackend.GenOpts = _summarizer.options_history[0]
	assert_eq(opts.max_tokens, 300)


func test_02_six_turns_do_not_trigger_generation() -> void:
	_backend.set_responses(["呼ばれてはいけない"])

	var result: Summarizer.SummaryResult = await _summarizer.summarize(
		_state(),
		"維持されるサマリー",
		_logs(6),
	)

	assert_false(result.triggered)
	assert_false(result.failed)
	assert_eq(result.summary, "維持されるサマリー")
	assert_eq(result.remaining_logs, _logs(6))
	assert_true(_summarizer.prompt_history.is_empty())


func test_03_missing_and_broken_summaries_rebuild_from_structured_state() -> void:
	_backend.set_responses(["欠落から再生成した要約", "破損から再生成した要約"])
	var state: GameState = _state()
	var missing_result: Summarizer.SummaryResult = await _summarizer.summarize(
		state,
		null,
		_logs(7),
	)
	var broken_result: Summarizer.SummaryResult = await _summarizer.summarize(
		state,
		{"unexpected": "dictionary"},
		_logs(7),
	)

	for result: Summarizer.SummaryResult in [missing_result, broken_result]:
		assert_true(result.triggered)
		assert_false(result.failed)
		assert_true(result.used_structured_fallback)
		assert_true(result.prompt.contains("structured_scene_marker"))
		assert_true(result.prompt.contains("structured_flag_marker"))
		assert_true(result.prompt.contains("structured_character_marker"))
		assert_true(result.prompt.contains("structured_item_marker"))
	assert_eq(missing_result.summary, "欠落から再生成した要約")
	assert_eq(broken_result.summary, "破損から再生成した要約")


func test_04_empty_generated_summary_falls_back_without_error() -> void:
	_backend.set_responses([""])

	var result: Summarizer.SummaryResult = await _summarizer.summarize(
		_state(),
		null,
		_logs(7),
	)

	assert_true(result.triggered)
	assert_false(result.failed)
	assert_true(result.used_structured_fallback)
	assert_true(result.summary.contains("structured_scene_marker"))
	assert_true(result.summary.contains("ターン0固有語"))
	assert_eq(result.remaining_logs.size(), 5)


func test_05_generation_failure_preserves_folded_logs_in_fallback() -> void:
	_backend.fail_on_generate = 1

	var result: Summarizer.SummaryResult = await _summarizer.summarize(
		_state(),
		"生成失敗前の既存サマリー",
		_logs(7),
	)

	assert_true(result.triggered)
	assert_true(result.failed)
	assert_true(result.used_structured_fallback)
	assert_true(result.summary.contains("structured_scene_marker"))
	assert_true(result.summary.contains("生成失敗前の既存サマリー"))
	assert_true(result.summary.contains("ターン0固有語"))
	assert_true(result.summary.contains("ターン1固有語"))
	assert_eq(result.remaining_logs, _logs(7).slice(2))


func test_06_prompt_template_is_loaded_from_file() -> void:
	var source: String = _read_text(SUMMARIZER_SOURCE_PATH)
	var prompt_template: String = _read_text(SUMMARIZE_PROMPT_PATH)
	var characteristic_lines: Array[String] = [
		"既存サマリーと今回畳み込むログを統合し、後の描写に必要な出来事、人物関係、未解決の手がかりを日本語で簡潔に残してください。",
		"構造化状態が他の記述と矛盾する場合は、必ず構造化状態を正として修正してください。",
	]

	assert_true(source.contains(SUMMARIZE_PROMPT_PATH))
	for line: String in characteristic_lines:
		assert_false(source.contains(line), "テンプレートの特徴的な行がソースに直書きされています。")
	assert_true(prompt_template.contains("{{existing_summary}}"))
	assert_true(prompt_template.contains("{{structured_context}}"))
	assert_true(prompt_template.contains("{{folded_logs}}"))


func test_07_summarize_does_not_mutate_game_state() -> void:
	var state: GameState = _state()
	var before: String = JSON.stringify(state.serialize())
	_backend.set_responses(["状態を変更しない要約"])

	var result: Summarizer.SummaryResult = await _summarizer.summarize(
		state,
		"既存サマリー",
		_logs(7),
	)

	assert_false(result.failed)
	assert_eq(JSON.stringify(state.serialize()), before)


func _state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "structured_scenario_marker"
	state.scene_id = "structured_scene_marker"
	state.turn_count = 7
	state.clock = 2
	state.flags = {"structured_flag_marker": true}
	state.active_enemies = [
		{
			"enemy_id": "structured_enemy_marker",
			"hp": {"current": 2, "max": 4},
		},
	]
	state.character.name = "structured_character_marker"
	state.character.description = "構造化状態から復元される人物"
	state.character.inventory = [
		{"item_id": "structured_item_marker", "count": 1},
	]
	return state


func _logs(count: int) -> Array[String]:
	var logs: Array[String] = []
	for index: int in range(count):
		logs.append("ターン%d固有語" % index)
	return logs


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	assert_not_null(file, "ファイルを開けません: %s" % path)
	if file == null:
		return ""
	return file.get_as_text()
