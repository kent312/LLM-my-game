extends GutTest

var _streamed_text: String
var _events: Array[String]
var _token_count: int
var _finished_count: int
var _failed_count: int


func before_each() -> void:
	_streamed_text = ""
	_events = []
	_token_count = 0
	_finished_count = 0
	_failed_count = 0


func test_streams_tokens_before_finished_with_complete_text() -> void:
	var backend: BackendMock = BackendMock.new()
	backend.set_responses(["古い扉が静かに開く。"])
	backend.token_size = 3
	backend.token_streamed.connect(_on_token_streamed)
	backend.generation_finished.connect(_on_generation_finished)

	backend.generate("扉を開ける", LLMBackend.GenOpts.new())
	var full_text: String = await backend.generation_finished

	assert_eq(_streamed_text, full_text)
	assert_eq(full_text, "古い扉が静かに開く。")
	assert_false(_events.is_empty())
	assert_eq(_events[-1], "finished")
	for event: String in _events.slice(0, -1):
		assert_eq(event, "token")


func test_cancel_stops_all_later_signals_during_delayed_response() -> void:
	var backend: BackendMock = BackendMock.new()
	backend.set_responses(["キャンセル対象の応答"])
	backend.token_size = 1
	backend.delay_ms = 20
	backend.token_streamed.connect(_on_counted_token)
	backend.generation_finished.connect(_on_counted_finished)
	backend.generation_failed.connect(_on_counted_failure)

	backend.generate("生成開始", LLMBackend.GenOpts.new())
	await backend.token_streamed
	var token_count_at_cancel: int = _token_count
	backend.cancel()
	await wait_seconds(0.15)

	assert_eq(_token_count, token_count_at_cancel)
	assert_eq(_finished_count, 0)
	assert_eq(_failed_count, 0)


func test_scripted_generate_number_emits_failure() -> void:
	var backend: BackendMock = BackendMock.new()
	backend.set_responses(["一回目", "二回目"])
	backend.fail_on_generate = 2

	backend.generate("一回目", LLMBackend.GenOpts.new())
	var first_text: String = await backend.generation_finished
	assert_eq(first_text, "一回目")

	backend.generate("二回目", LLMBackend.GenOpts.new())
	var error: Variant = await backend.generation_failed

	assert_true(error is LLMBackend.LLMError)
	assert_eq(error.code, "mock_generation_failed")
	assert_true(error.message.contains("2回目"))


func _on_token_streamed(text: String) -> void:
	_streamed_text += text
	_events.append("token")


func _on_generation_finished(_full_text: String) -> void:
	_events.append("finished")


func _on_counted_token(_text: String) -> void:
	_token_count += 1


func _on_counted_finished(_full_text: String) -> void:
	_finished_count += 1


func _on_counted_failure(_error: Variant) -> void:
	_failed_count += 1
