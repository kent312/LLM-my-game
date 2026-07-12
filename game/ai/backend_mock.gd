class_name BackendMock
extends LLMBackend

var responses: Array[String] = []
var token_size: int = 1
var delay_ms: int = 0
var fail_on_generate: int = 0
var constrained_output_supported: bool = true

var _generate_count: int = 0
var _response_index: int = 0
var _request_id: int = 0
var _cancelled: bool = false


func set_responses(scripted_responses: Array[String]) -> void:
	responses = scripted_responses.duplicate()
	_response_index = 0


func generate(_prompt: String, _opts: GenOpts) -> void:
	_generate_count += 1
	_request_id += 1
	_cancelled = false

	var current_request_id: int = _request_id
	var response: String = ""
	if _response_index < responses.size():
		response = responses[_response_index]
	_response_index += 1

	# deferred 呼び出しにより、遅延0でも generate() の呼び出し元をブロックしない。
	call_deferred("_run_generation", response, _generate_count, current_request_id)


func cancel() -> void:
	_cancelled = true
	_request_id += 1


func is_available() -> bool:
	return true


func supports_constrained_output() -> bool:
	return constrained_output_supported


func _run_generation(response: String, call_number: int, request_id: int) -> void:
	if not _is_active(request_id):
		return
	if call_number == fail_on_generate:
		generation_failed.emit(
			LLMError.new(
				"mock_generation_failed",
				"モックの台本に従って生成に失敗しました（%d回目）。" % call_number,
			)
		)
		return

	var chunk_size: int = maxi(token_size, 1)
	var offset: int = 0
	while offset < response.length():
		if delay_ms > 0:
			var tree: SceneTree = Engine.get_main_loop() as SceneTree
			if tree == null:
				if _is_active(request_id):
					generation_failed.emit(
						LLMError.new(
							"scene_tree_unavailable",
							"遅延生成に必要な SceneTree を取得できません。",
						)
					)
				return
			await tree.create_timer(float(delay_ms) / 1000.0).timeout
		if not _is_active(request_id):
			return
		var token: String = response.substr(offset, chunk_size)
		token_streamed.emit(token)
		offset += chunk_size

	if _is_active(request_id):
		generation_finished.emit(response)


func _is_active(request_id: int) -> bool:
	return not _cancelled and request_id == _request_id
