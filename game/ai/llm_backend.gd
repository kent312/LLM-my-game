class_name LLMBackend

signal token_streamed(text: String)
signal generation_finished(full_text: String)
signal generation_failed(error: Variant)


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


func generate(prompt: String, opts: GenOpts) -> void:
	# 基底型の誤使用でも呼び出し元をブロックせず、非同期に失敗を通知する。
	call_deferred("_emit_not_implemented_error", prompt, opts)


func cancel() -> void:
	pass


func is_available() -> bool:
	return false


func supports_constrained_output() -> bool:
	return false


func _emit_not_implemented_error(_prompt: String, _opts: GenOpts) -> void:
	generation_failed.emit(
		LLMError.new(
			"backend_not_implemented",
			"LLMバックエンドが実装されていません。",
		)
	)
