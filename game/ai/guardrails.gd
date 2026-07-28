class_name Guardrails
extends RefCounted

signal sentence_ready(text: String)
signal generation_discarded(attempt_index: int)
signal output_finished(result: Variant)
signal output_failed(error: Variant)
signal _generation_settled(response: String, error: Variant)

const DICTIONARY_PATH: String = "res://game/data/ng_words.json"
const REQUIRED_CATEGORIES: Array[String] = [
	"jailbreak",
	"sexual",
	"discrimination",
	"real_person",
]
const OUTPUT_CATEGORIES: Array[String] = [
	"sexual",
	"discrimination",
	"real_person",
]
const RETRY_TEMPERATURE_MULTIPLIER: float = 0.5


class FilterMatch:
	var category: String = ""
	var value: String = ""
	var matched_by_pattern: bool = false


class InputResult:
	var blocked: bool = false
	var response: String = ""
	var matches: Array[FilterMatch] = []
	# 辞書異常の診断専用で、UIへ直接表示しない。
	var diagnostic: String = ""


class OutputResult:
	var text: String = ""
	var regeneration_count: int = 0
	var used_fallback: bool = false
	var failed: bool = false
	var error: Variant = null
	var matches: Array[FilterMatch] = []


class GenerationAttempt:
	var response: String = ""
	var failed: bool = false
	var error: Variant = null


var prompt_history: Array[String] = []
var options_history: Array[Variant] = []

var _backend: LLMBackend
var _dictionary_path: String
var _categories: Dictionary = {}
var _compiled_patterns: Dictionary = {}
var _dictionary_error: String = ""
var _waiting_for_generation: bool = false
var _generation_in_progress: bool = false
var _sentence_buffer: String = ""
var _sentence_scan_index: int = 0
var _attempt_index: int = 0
var _attempt_cumulative_text: String = ""
var _attempt_discarded: bool = false
var _attempt_release_stopped: bool = false


func _init(
	backend: LLMBackend = null,
	dictionary_path: String = DICTIONARY_PATH,
) -> void:
	_backend = backend
	_dictionary_path = dictionary_path
	_load_dictionary()
	if _backend == null:
		return
	_backend.token_streamed.connect(_on_token_streamed)
	_backend.generation_finished.connect(_on_generation_finished)
	_backend.generation_failed.connect(_on_generation_failed)


func filter_input(player_input: String) -> InputResult:
	var result: InputResult = InputResult.new()
	if not _dictionary_error.is_empty():
		# INV-8: 辞書を適用できない場合も入力を素通りさせず、安全側で分類前に止める。
		result.blocked = true
		result.response = _input_fallback_text()
		result.diagnostic = _dictionary_error
		return result
	result.matches = _find_matches(player_input, ["jailbreak"])
	result.blocked = not result.matches.is_empty()
	if result.blocked:
		result.response = _input_fallback_text()
	return result


func generate_filtered(prompt: String, opts: LLMBackend.GenOpts) -> OutputResult:
	var result: OutputResult = OutputResult.new()
	if _generation_in_progress or _waiting_for_generation:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"guardrails_generation_in_progress",
			tr("ガードレール付き生成はすでに実行中です。"),
		)
		# 実行中の生成に属するリスナーを誤作動させないよう、再入拒否は戻り値だけで通知する。
		return result
	if _backend == null:
		result.failed = true
		result.error = LLMBackend.LLMError.new(
			"guardrails_backend_unavailable",
			tr("ガードレール付き生成にLLMバックエンドが設定されていません。"),
		)
		output_failed.emit(result.error)
		return result
	if not _dictionary_error.is_empty():
		# INV-8: 出力辞書の破損時は未検査テキストを生成・表示しない。
		result.text = _output_fallback_text()
		result.used_fallback = true
		sentence_ready.emit(result.text)
		output_finished.emit(result)
		return result

	_generation_in_progress = true
	prompt_history.clear()
	options_history.clear()

	var first_opts: LLMBackend.GenOpts = _copy_options(opts)
	var first_attempt: GenerationAttempt = await _generate_once(prompt, first_opts, 0)
	if first_attempt.failed:
		_discard_current_attempt()
		_generation_in_progress = false
		result.failed = true
		result.error = first_attempt.error
		output_failed.emit(result.error)
		return result

	var first_matches: Array[FilterMatch] = _find_matches(
		first_attempt.response,
		OUTPUT_CATEGORIES,
	)
	if first_matches.is_empty():
		_generation_in_progress = false
		result.text = first_attempt.response
		output_finished.emit(result)
		return result

	# §10-2 / INV-8: NG判定された試行を表示側から破棄してから次の試行へ進む。
	_discard_current_attempt()
	result.matches.append_array(first_matches)
	if opts.temperature <= 0.0:
		# これ以上温度を下げられない場合は同温度で再生成せず、定型文へ安全側に倒す。
		_generation_in_progress = false
		result.text = _output_fallback_text()
		result.used_fallback = true
		sentence_ready.emit(result.text)
		output_finished.emit(result)
		return result

	# §10-2: 完成出力のNGヒット時だけ一度再生成し、同じ要求を低温で行う。
	result.regeneration_count = 1
	var retry_opts: LLMBackend.GenOpts = _copy_options(opts)
	retry_opts.temperature = opts.temperature * RETRY_TEMPERATURE_MULTIPLIER
	var retry_attempt: GenerationAttempt = await _generate_once(prompt, retry_opts, 1)
	if retry_attempt.failed:
		_discard_current_attempt()
		_generation_in_progress = false
		result.failed = true
		result.error = retry_attempt.error
		output_failed.emit(result.error)
		return result

	var retry_matches: Array[FilterMatch] = _find_matches(
		retry_attempt.response,
		OUTPUT_CATEGORIES,
	)
	_generation_in_progress = false
	if retry_matches.is_empty():
		result.text = retry_attempt.response
		output_finished.emit(result)
		return result

	_discard_current_attempt()
	result.matches.append_array(retry_matches)
	result.text = _output_fallback_text()
	result.used_fallback = true
	sentence_ready.emit(result.text)
	output_finished.emit(result)
	return result


func _generate_once(
	prompt: String,
	opts: LLMBackend.GenOpts,
	attempt_index: int,
) -> GenerationAttempt:
	var attempt: GenerationAttempt = GenerationAttempt.new()
	_attempt_index = attempt_index
	_attempt_cumulative_text = ""
	_attempt_discarded = false
	_attempt_release_stopped = false
	_sentence_buffer = ""
	_sentence_scan_index = 0
	prompt_history.append(prompt)
	options_history.append(opts)
	_waiting_for_generation = true
	# 同期発火するバックエンドでもawait登録前に完了通知を失わないよう遅延する。
	_backend.generate.call_deferred(prompt, opts)
	var settled: Array = await _generation_settled
	_waiting_for_generation = false
	attempt.response = String(settled[0])
	attempt.error = settled[1]
	attempt.failed = attempt.error != null
	if attempt.failed:
		_sentence_buffer = ""
	else:
		_flush_sentence_buffer()
	return attempt


func _on_token_streamed(text: String) -> void:
	if not _waiting_for_generation or _attempt_release_stopped:
		return
	_sentence_buffer += text
	_release_complete_sentences()


func _release_complete_sentences() -> void:
	# 既に走査した未確定部分を再走査せず、追記された文字だけを順に調べる。
	while _sentence_scan_index < _sentence_buffer.length():
		var character: String = _sentence_buffer.substr(_sentence_scan_index, 1)
		_sentence_scan_index += 1
		if not _is_sentence_boundary(character):
			continue
		var sentence: String = _sentence_buffer.substr(0, _sentence_scan_index)
		_sentence_buffer = _sentence_buffer.substr(_sentence_scan_index)
		_sentence_scan_index = 0
		_release_sentence(sentence)
		if _attempt_release_stopped:
			_sentence_buffer = ""
			return


func _flush_sentence_buffer() -> void:
	if _sentence_buffer.is_empty() or _attempt_release_stopped:
		_sentence_buffer = ""
		_sentence_scan_index = 0
		return
	var sentence: String = _sentence_buffer
	_sentence_buffer = ""
	_sentence_scan_index = 0
	_release_sentence(sentence)


func _release_sentence(sentence: String) -> void:
	# §10-3: 全文照合と同じ累積テキストで検査し、文境界を跨ぐNGも表示確定前に止める。
	_attempt_cumulative_text += sentence
	if _attempt_release_stopped:
		return
	if not _find_matches(_attempt_cumulative_text, OUTPUT_CATEGORIES).is_empty():
		_discard_current_attempt()
		return
	# 改行だけなどの空白センテンスは表示用断片として通知しない。
	if sentence.strip_edges().is_empty():
		return
	sentence_ready.emit(sentence)


func _is_sentence_boundary(character: String) -> bool:
	# ASCIIピリオドは小数・略語の途中で誤分割しやすいため含めず、生成完了時に残余を確定する。
	return character in ["。", "！", "？", "!", "?", "\n"]


func _discard_current_attempt() -> void:
	if _attempt_discarded:
		return
	_attempt_discarded = true
	_attempt_release_stopped = true
	_sentence_buffer = ""
	_sentence_scan_index = 0
	generation_discarded.emit(_attempt_index)


func _find_matches(text: String, category_names: Array[String]) -> Array[FilterMatch]:
	var matches: Array[FilterMatch] = []
	var normalized_text: String = text.to_lower()
	for category_name: String in category_names:
		var category_value: Variant = _categories.get(category_name, {})
		if typeof(category_value) != TYPE_DICTIONARY:
			continue
		var category: Dictionary = category_value
		var terms_value: Variant = category.get("terms", [])
		if typeof(terms_value) == TYPE_ARRAY:
			var terms: Array = terms_value
			for term_value: Variant in terms:
				var term: String = String(term_value)
				if not term.is_empty() and normalized_text.contains(term.to_lower()):
					var term_match: FilterMatch = FilterMatch.new()
					term_match.category = category_name
					term_match.value = term
					matches.append(term_match)

		var patterns_value: Variant = _compiled_patterns.get(category_name, [])
		if typeof(patterns_value) != TYPE_ARRAY:
			continue
		var patterns: Array = patterns_value
		for regex_value: Variant in patterns:
			if not regex_value is RegEx:
				continue
			var regex: RegEx = regex_value
			var regex_match: RegExMatch = regex.search(text)
			if regex_match == null:
				continue
			var pattern_match: FilterMatch = FilterMatch.new()
			pattern_match.category = category_name
			pattern_match.value = regex_match.get_string()
			pattern_match.matched_by_pattern = true
			matches.append(pattern_match)
	return matches


func _load_dictionary() -> void:
	var file: FileAccess = FileAccess.open(_dictionary_path, FileAccess.READ)
	if file == null:
		_dictionary_error = (
			"NGワード辞書を開けません: %s"
			% error_string(FileAccess.get_open_error())
		)
		return
	var json: JSON = JSON.new()
	if json.parse(file.get_as_text()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		_dictionary_error = "NGワード辞書を解析できません。"
		return
	var root: Dictionary = json.data
	for category_name: String in REQUIRED_CATEGORIES:
		var category_value: Variant = root.get(category_name)
		if typeof(category_value) != TYPE_DICTIONARY:
			_dictionary_error = "NGワード辞書にカテゴリがありません: %s" % category_name
			return
		var category: Dictionary = category_value
		if not _load_category(category_name, category):
			return
		_categories[category_name] = category.duplicate(true)


func _load_category(category_name: String, category: Dictionary) -> bool:
	var terms_value: Variant = category.get("terms")
	var patterns_value: Variant = category.get("patterns")
	if typeof(terms_value) != TYPE_ARRAY or typeof(patterns_value) != TYPE_ARRAY:
		_dictionary_error = "NGワード辞書のterms/patternsが配列ではありません: %s" % category_name
		return false
	var terms: Array = terms_value
	var patterns: Array = patterns_value
	if terms.is_empty() and patterns.is_empty():
		_dictionary_error = "NGワード辞書のカテゴリが空です: %s" % category_name
		return false
	for term_value: Variant in terms:
		if typeof(term_value) != TYPE_STRING or String(term_value).is_empty():
			_dictionary_error = "NGワード辞書のtermsに不正な値があります: %s" % category_name
			return false

	var compiled: Array[RegEx] = []
	for pattern_value: Variant in patterns:
		if typeof(pattern_value) != TYPE_STRING or String(pattern_value).is_empty():
			_dictionary_error = "NGワード辞書のpatternsに不正な値があります: %s" % category_name
			return false
		var regex: RegEx = RegEx.new()
		# termsと同じく大文字小文字を区別せず照合するため、全patternへフラグを強制する。
		var case_insensitive_pattern: String = "(?i)(?:%s)" % String(pattern_value)
		if regex.compile(case_insensitive_pattern) != OK:
			_dictionary_error = "NGワード辞書に不正な正規表現があります: %s" % category_name
			return false
		compiled.append(regex)
	_compiled_patterns[category_name] = compiled
	return true


func _copy_options(source: LLMBackend.GenOpts) -> LLMBackend.GenOpts:
	var copied: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	copied.max_tokens = source.max_tokens
	copied.temperature = source.temperature
	copied.grammar = source.grammar
	copied.json_schema = source.json_schema.duplicate(true)
	copied.stop = source.stop.duplicate()
	return copied


func _input_fallback_text() -> String:
	return tr("そのお願いには応じられません。別の行動を試してください。")


func _output_fallback_text() -> String:
	return tr("GMは少し考え込んだ。……場面を仕切り直そう。")


func _on_generation_finished(full_text: String) -> void:
	if _waiting_for_generation:
		_generation_settled.emit(full_text, null)


func _on_generation_failed(error: Variant) -> void:
	if _waiting_for_generation:
		_generation_settled.emit("", error)
