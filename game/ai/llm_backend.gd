class_name LLMBackend

class LLMError:
	var code: String
	var message: String


	func _init(error_code: String, error_message: String) -> void:
		code = error_code
		message = error_message


class GenOpts:
	var max_tokens: int = 400
	var temperature: float = 0.8
	var grammar: String = ""
	var json_schema: Dictionary = {}
	var stop: Array[String] = []
	# 外部送信時だけ参照する、仕様書4.5のallowlist済み文脈。
	# ローカル/モックは従来通りgenerate()のpromptだけを利用する。
	var external_context: Dictionary[String, String] = {}


signal token_streamed(text: String)
signal generation_finished(full_text: String)
signal generation_failed(error: LLMError)
signal fallback_switch_proposed(error: LLMError)
signal fallback_declined()
signal fallback_mode_changed(using_fallback: bool)
signal constrained_output_support_changed(supported: bool)


func generate(prompt: String, opts: GenOpts) -> void:
	# 基底型の誤使用でも呼び出し元をブロックせず、非同期に失敗を通知する。
	call_deferred("_emit_not_implemented_error", prompt, opts)


func cancel() -> void:
	pass


func is_available() -> bool:
	return false


func supports_constrained_output() -> bool:
	return false


func respond_to_fallback(_accepted: bool) -> void:
	pass


func retry_pending_request() -> void:
	pass


func has_pending_fallback() -> bool:
	return false


func _emit_not_implemented_error(_prompt: String, _opts: GenOpts) -> void:
	generation_failed.emit(
		LLMError.new(
			"backend_not_implemented",
			tr("LLMバックエンドが実装されていません。"),
		)
	)
