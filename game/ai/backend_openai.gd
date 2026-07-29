class_name BackendOpenAI
extends LLMBackend

signal _http_request_settled(request_id: int, response: Dictionary)

const CHAT_COMPLETIONS_PATH: String = "/v1/chat/completions"
const MAX_RETRIES: int = 3
const ALLOWED_CONTEXT_FIELDS: Array[String] = [
	"system_prompt",
	"character_sheet_summary",
	"current_scene",
	"conversation_history",
	"conversation_summary",
	"player_input",
]

var endpoint: String
var api_key: String
var model: String
var timeout_seconds: float = 30.0
var retry_base_delay_ms: int = 250

var request_count: int = 0
var last_payload: Dictionary[String, Variant] = {}
var pending_prompt: String = ""
var waiting_for_fallback_choice: bool = false
var http_request_factory: Callable
var http_request_starter: Callable

var _request_sender: Callable
var _fallback_backend: LLMBackend
var _pending_options: GenOpts = GenOpts.new()
var _structured_output_supported: bool = false
var _structured_output_checked: bool = false
var _request_id: int = 0
var _cancelled: bool = false
var _active_http_request: HTTPRequest
var _active_http_request_id: int = 0
var _fallback_forwarding: bool = false
var _fallback_next_request: bool = false


func _init(
	target_endpoint: String = "",
	secret_api_key: String = "",
	target_model: String = "",
	request_sender: Callable = Callable(),
) -> void:
	endpoint = target_endpoint.strip_edges().trim_suffix("/")
	api_key = secret_api_key
	model = target_model.strip_edges()
	_request_sender = request_sender


func generate(prompt: String, opts: GenOpts) -> void:
	_request_id += 1
	_cancelled = false
	if _fallback_next_request and _fallback_backend != null:
		_fallback_next_request = false
		waiting_for_fallback_choice = false
		pending_prompt = ""
		_forward_fallback_generation(prompt, _copy_options(opts))
		return
	waiting_for_fallback_choice = false
	pending_prompt = ""
	var current_request_id: int = _request_id
	call_deferred("_run_generation", prompt, _copy_options(opts), current_request_id)


func cancel() -> void:
	_cancelled = true
	_request_id += 1
	waiting_for_fallback_choice = false
	pending_prompt = ""
	_fallback_forwarding = false
	_fallback_next_request = false
	if _active_http_request != null:
		var cancelled_request: HTTPRequest = _active_http_request
		var cancelled_request_id: int = _active_http_request_id
		_active_http_request = null
		_active_http_request_id = 0
		cancelled_request.queue_free()
		_http_request_settled.emit(
			cancelled_request_id,
			{
				"cancelled": true,
				"result": HTTPRequest.RESULT_REQUEST_FAILED,
				"status_code": 0,
			},
		)
	if _fallback_backend != null:
		_fallback_backend.cancel()


func is_available() -> bool:
	return (
		not endpoint.is_empty()
		and (endpoint.begins_with("http://") or endpoint.begins_with("https://"))
	)


func supports_constrained_output() -> bool:
	# 未検出時は楽観的にJSON Schemaを送って接続先の対応可否を判定する。
	# 非対応を一度確認した後だけfalseとなり、以後response_formatを付けない。
	return not _structured_output_checked or _structured_output_supported


func set_fallback_backend(backend: LLMBackend) -> void:
	if _fallback_backend != null:
		if _fallback_backend.token_streamed.is_connected(_on_fallback_token_streamed):
			_fallback_backend.token_streamed.disconnect(_on_fallback_token_streamed)
		if _fallback_backend.generation_finished.is_connected(_on_fallback_generation_finished):
			_fallback_backend.generation_finished.disconnect(_on_fallback_generation_finished)
		if _fallback_backend.generation_failed.is_connected(_on_fallback_generation_failed):
			_fallback_backend.generation_failed.disconnect(_on_fallback_generation_failed)
	_fallback_backend = backend
	if _fallback_backend != null:
		_fallback_backend.token_streamed.connect(_on_fallback_token_streamed)
		_fallback_backend.generation_finished.connect(_on_fallback_generation_finished)
		_fallback_backend.generation_failed.connect(_on_fallback_generation_failed)


func respond_to_fallback(accepted: bool) -> void:
	if not waiting_for_fallback_choice:
		return
	if not accepted:
		# 入力と生成待機を保持する。通信もゲーム状態更新も行わない。
		fallback_declined.emit()
		return
	if _fallback_backend == null:
		waiting_for_fallback_choice = false
		fallback_declined.emit()
		return
	waiting_for_fallback_choice = false
	pending_prompt = ""
	_fallback_next_request = true
	fallback_mode_changed.emit(true)


func retry_pending_request() -> void:
	if not waiting_for_fallback_choice:
		return
	waiting_for_fallback_choice = false
	pending_prompt = ""
	_fallback_next_request = false
	fallback_mode_changed.emit(false)


func has_pending_fallback() -> bool:
	return waiting_for_fallback_choice


static func build_inference_payload(
	context: Dictionary,
	opts: GenOpts,
	target_model: String,
) -> Dictionary[String, Variant]:
	# 外部送信コンテキストはこの関数だけで組み立てる。入力辞書にセーブ全体や
	# アカウント/ハードウェア情報が混入しても、allowlist外はコピーしない。
	var allowed: Dictionary[String, String] = {}
	for field_name: String in ALLOWED_CONTEXT_FIELDS:
		if context.has(field_name):
			allowed[field_name] = String(context[field_name])
	var messages: Array[Dictionary] = []
	var system_prompt: String = allowed.get("system_prompt", "")
	if not system_prompt.is_empty():
		messages.append({"role": "system", "content": system_prompt})
	var contextual_sections: Array[String] = []
	for field_name: String in [
		"character_sheet_summary",
		"current_scene",
		"conversation_history",
		"conversation_summary",
	]:
		var value: String = allowed.get(field_name, "")
		if not value.is_empty():
			contextual_sections.append("%s:\n%s" % [field_name, value])
	var player_input: String = allowed.get("player_input", "")
	if not contextual_sections.is_empty():
		messages.append(
			{"role": "system", "content": "\n\n".join(contextual_sections)}
		)
	if not player_input.is_empty():
		messages.append({"role": "user", "content": player_input})
	var payload: Dictionary[String, Variant] = {
		"model": target_model,
		"messages": messages,
		"stream": false,
		"max_tokens": opts.max_tokens,
		"temperature": opts.temperature,
	}
	if not opts.stop.is_empty():
		payload["stop"] = opts.stop.duplicate()
	if not opts.json_schema.is_empty():
		payload["response_format"] = {
			"type": "json_schema",
			"json_schema": {
				"name": "game_response",
				"strict": true,
				"schema": opts.json_schema.duplicate(true),
			},
		}
	return payload


func _run_generation(prompt: String, opts: GenOpts, request_id: int) -> void:
	if not is_available():
		generation_failed.emit(
			LLMError.new("external_backend_unavailable", tr("外部AIの送信先が未設定です。"))
		)
		return
	var context: Dictionary = opts.external_context.duplicate(true)
	if context.is_empty():
		# 旧来のgenerate(prompt)呼び出しも、互換サーバが受理しやすいuserロールで送る。
		context = {"player_input": prompt}
	var payload_options: GenOpts = _copy_options(opts)
	if _structured_output_checked and not _structured_output_supported:
		payload_options.json_schema.clear()
	var payload: Dictionary[String, Variant] = build_inference_payload(
		context,
		payload_options,
		model,
	)
	var last_error: LLMError = null
	for attempt: int in range(MAX_RETRIES + 1):
		if not _is_active(request_id):
			return
		last_payload = payload.duplicate(true)
		var response: Dictionary = await _send_request(payload, request_id)
		if not _is_active(request_id):
			return
		if _is_success(response):
			if payload.has("response_format"):
				_set_structured_output_support(true)
			var full_text: String = _emit_response_content(response)
			generation_finished.emit(full_text)
			return
		if (
			payload.has("response_format")
			and not _structured_output_checked
			and _is_structured_output_unsupported(response)
		):
			_set_structured_output_support(false)
			payload.erase("response_format")
			# 対応検出のための失敗は通常の通信リトライ回数に数えない。
			var unconstrained: Dictionary = await _send_request(
				payload,
				request_id,
			)
			if not _is_active(request_id):
				return
			if _is_success(unconstrained):
				var unconstrained_text: String = _emit_response_content(unconstrained)
				generation_finished.emit(unconstrained_text)
				return
			response = unconstrained
		last_error = _error_from_response(response)
		if attempt < MAX_RETRIES:
			await _backoff(attempt)
	_pending_options = _copy_options(opts)
	pending_prompt = prompt
	waiting_for_fallback_choice = true
	# PR-13完了までは、呼び出し側がPreviewBackendFactory(mock)を同梱モデル代替として注入する。
	fallback_switch_proposed.emit(last_error)
	# UI判断とは独立にLLMBackendの生成契約を必ず終端させ、await連鎖を解放する。
	generation_failed.emit(last_error)


func _send_request(
	payload: Dictionary[String, Variant],
	request_id: int,
) -> Dictionary[String, Variant]:
	request_count += 1
	if _request_sender.is_valid():
		var injected_result: Variant = await _request_sender.call(payload.duplicate(true))
		if typeof(injected_result) == TYPE_DICTIONARY:
			var typed_result: Dictionary[String, Variant] = {}
			var source: Dictionary = injected_result
			for key_value: Variant in source.keys():
				typed_result[String(key_value)] = source[key_value]
			return typed_result
		return {"transport_error": tr("モック送信関数の戻り値が不正です。")}

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return {
			"transport_error": tr("HTTP送信に必要なSceneTreeを取得できません。")
		}
	var request: HTTPRequest = _create_http_request()
	if request == null:
		return {"transport_error": tr("HTTP送信ノードを作成できません。")}
	request.timeout = timeout_seconds
	tree.root.add_child(request)
	_active_http_request = request
	_active_http_request_id = request_id
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	if not api_key.is_empty():
		headers.append("Authorization: Bearer %s" % api_key)
	request.request_completed.connect(
		_on_http_request_completed.bind(request_id),
		CONNECT_ONE_SHOT,
	)
	var start_error: Error = OK
	if http_request_starter.is_valid():
		start_error = http_request_starter.call(
			request,
			endpoint + CHAT_COMPLETIONS_PATH,
			headers,
			JSON.stringify(payload),
		)
	else:
		start_error = request.request(
			endpoint + CHAT_COMPLETIONS_PATH,
			headers,
			HTTPClient.METHOD_POST,
			JSON.stringify(payload),
		)
	if start_error != OK:
		request.queue_free()
		_active_http_request = null
		_active_http_request_id = 0
		return {"transport_error": error_string(start_error)}
	var settled: Array = await _http_request_settled
	if int(settled[0]) != request_id:
		return {
			"cancelled": true,
			"result": HTTPRequest.RESULT_REQUEST_FAILED,
			"status_code": 0,
		}
	var response_value: Variant = settled[1]
	if typeof(response_value) != TYPE_DICTIONARY:
		return {"transport_error": tr("HTTP応答の内部形式が不正です。")}
	var response: Dictionary = response_value
	return response


func _emit_response_content(response: Dictionary[String, Variant]) -> String:
	var body: String = String(response.get("body", ""))
	var parsed: Variant = JSON.parse_string(body)
	var full_text: String = _content_from_json(parsed)
	if not full_text.is_empty():
		token_streamed.emit(full_text)
	return full_text


func _content_from_json(parsed: Variant) -> String:
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var root: Dictionary = parsed
	var choices_value: Variant = root.get("choices", [])
	if typeof(choices_value) != TYPE_ARRAY or choices_value.is_empty():
		return ""
	var choices: Array = choices_value
	if typeof(choices[0]) != TYPE_DICTIONARY:
		return ""
	var choice: Dictionary = choices[0]
	var message_value: Variant = choice.get("message", {})
	if typeof(message_value) != TYPE_DICTIONARY:
		return ""
	var message: Dictionary = message_value
	return String(message.get("content", ""))


func _is_success(response: Dictionary[String, Variant]) -> bool:
	if (
		response.has("result")
		and int(response["result"]) != HTTPRequest.RESULT_SUCCESS
	):
		return false
	var status_code: int = int(response.get("status_code", 0))
	return status_code >= 200 and status_code < 300


func _is_structured_output_unsupported(response: Dictionary[String, Variant]) -> bool:
	var status_code: int = int(response.get("status_code", 0))
	if status_code < 400 or status_code >= 500:
		return false
	var body: String = String(response.get("body", "")).to_lower()
	return (
		body.contains("response_format")
		or body.contains("json_schema")
		or body.contains("structured output")
	)


func _error_from_response(response: Dictionary[String, Variant]) -> LLMError:
	if response.has("transport_error"):
		return LLMError.new(
			"external_transport_error",
			tr("外部AIへの接続に失敗しました: %s") % String(response["transport_error"]),
		)
	if bool(response.get("cancelled", false)):
		return LLMError.new(
			"external_request_cancelled",
			tr("外部AIへの接続をキャンセルしました。"),
		)
	if response.has("result"):
		var result_code: int = int(response["result"])
		if result_code != HTTPRequest.RESULT_SUCCESS:
			return _request_result_error(result_code)
	return LLMError.new(
		"external_http_error",
		tr("外部AIがエラーを返しました（HTTP %d）。")
		% int(response.get("status_code", 0)),
	)


func _backoff(attempt: int) -> void:
	if retry_base_delay_ms <= 0:
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		var delay_ms: int = retry_base_delay_ms * (1 << attempt)
		await tree.create_timer(float(delay_ms) / 1000.0).timeout


func _forward_fallback_generation(prompt: String, opts: GenOpts) -> void:
	_fallback_forwarding = true
	_fallback_backend.generate(prompt, opts)


func _on_fallback_token_streamed(text: String) -> void:
	if _fallback_forwarding:
		token_streamed.emit(text)


func _on_fallback_generation_finished(text: String) -> void:
	if not _fallback_forwarding:
		return
	_fallback_forwarding = false
	fallback_mode_changed.emit(false)
	generation_finished.emit(text)


func _on_fallback_generation_failed(error: LLMError) -> void:
	if not _fallback_forwarding:
		return
	_fallback_forwarding = false
	fallback_mode_changed.emit(false)
	generation_failed.emit(error)


func _copy_options(source: GenOpts) -> GenOpts:
	var copy: GenOpts = GenOpts.new()
	copy.max_tokens = source.max_tokens
	copy.temperature = source.temperature
	copy.grammar = source.grammar
	copy.json_schema = source.json_schema.duplicate(true)
	copy.stop = source.stop.duplicate()
	copy.external_context = source.external_context.duplicate(true)
	return copy


func _is_active(request_id: int) -> bool:
	return not _cancelled and request_id == _request_id


func _set_structured_output_support(supported: bool) -> void:
	var changed: bool = (
		not _structured_output_checked
		or _structured_output_supported != supported
	)
	_structured_output_checked = true
	_structured_output_supported = supported
	if changed:
		constrained_output_support_changed.emit(supported)


func _create_http_request() -> HTTPRequest:
	if http_request_factory.is_valid():
		var created: Variant = http_request_factory.call()
		if created is HTTPRequest:
			return created
		return null
	return HTTPRequest.new()


func _on_http_request_completed(
	result: int,
	status_code: int,
	headers: PackedStringArray,
	body: PackedByteArray,
	request_id: int,
) -> void:
	if request_id != _active_http_request_id:
		return
	var completed_request: HTTPRequest = _active_http_request
	_active_http_request = null
	_active_http_request_id = 0
	if completed_request != null:
		completed_request.queue_free()
	_http_request_settled.emit(
		request_id,
		{
			"result": result,
			"status_code": status_code,
			"headers": headers,
			"body": body.get_string_from_utf8(),
		},
	)


func _request_result_error(result_code: int) -> LLMError:
	match result_code:
		HTTPRequest.RESULT_TIMEOUT:
			return LLMError.new(
				"external_timeout",
				tr("外部AIへの接続がタイムアウトしました。"),
			)
		HTTPRequest.RESULT_CANT_RESOLVE:
			return LLMError.new(
				"external_cannot_resolve",
				tr("外部AIの送信先アドレスを解決できませんでした。"),
			)
		HTTPRequest.RESULT_CANT_CONNECT:
			return LLMError.new(
				"external_cannot_connect",
				tr("外部AIの送信先へ接続できませんでした。"),
			)
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return LLMError.new(
				"external_tls_error",
				tr("外部AIとの安全な接続を確立できませんでした。"),
			)
		_:
			return LLMError.new(
				"external_request_failed",
				tr("外部AIへの通信に失敗しました（通信結果 %d）。") % result_code,
			)
