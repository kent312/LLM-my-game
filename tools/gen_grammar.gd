extends SceneTree

const DEFAULT_INPUT_PATH: String = "res://game/data/skill_tags.json"
const DEFAULT_OUTPUT_DIR: String = "res://game/data/generated"
const GBNF_FILE_NAME: String = "intent.gbnf"
const SCHEMA_FILE_NAME: String = "intent_schema.json"

# この番兵値は静的テンプレート専用であり、分類時の許可値ではない。
# PR-09 の意図分類器は GameState から target ID を列挙し、GBNF の
# target-enum 規則の右辺と JSON Schema の target.enum 配列を実行時に置換する。
const TARGET_ENUM_PLACEHOLDER: String = "__TARGET_ENUM_RUNTIME__"

const ACTION_TYPES: Array[String] = ["check", "talk", "move", "item", "attack", "other"]
const ABILITY_IDS: Array[String] = ["STR", "DEX", "CON", "INT", "WIS", "CHA"]
const DIFFICULTIES: Array[String] = ["easy", "normal", "hard"]
const REQUIRED_TAG_FIELDS: Array[String] = ["id", "label_ja", "hint_ja"]


class TagLoadResult:
	var ids: Array[String] = []
	var error: Error = OK


func _init() -> void:
	var options: Dictionary[String, String] = {
		"input": DEFAULT_INPUT_PATH,
		"output": DEFAULT_OUTPUT_DIR,
	}
	var argument_error: Error = _parse_cli_arguments(OS.get_cmdline_user_args(), options)
	if argument_error != OK:
		quit(1)
		return

	var generation_error: Error = generate(options["input"], options["output"])
	if generation_error != OK:
		quit(1)
		return

	print("意図分類の文法とJSONスキーマを生成しました: %s" % options["output"])
	quit(0)


static func generate(input_path: String, output_dir: String) -> Error:
	if input_path.is_empty():
		printerr("タグタクソノミーの入力パスが空です。")
		return ERR_INVALID_PARAMETER
	if output_dir.is_empty():
		printerr("生成物の出力先が空です。")
		return ERR_INVALID_PARAMETER

	var load_result: TagLoadResult = _load_tag_ids(input_path)
	if load_result.error != OK:
		return load_result.error

	var absolute_output_dir: String = ProjectSettings.globalize_path(output_dir)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(absolute_output_dir)
	if directory_error != OK:
		printerr(
			"生成物の出力ディレクトリを作成できません: %s（%s）"
			% [output_dir, error_string(directory_error)]
		)
		return directory_error

	var gbnf_path: String = output_dir.path_join(GBNF_FILE_NAME)
	var gbnf_error: Error = _write_text(gbnf_path, _build_gbnf(load_result.ids))
	if gbnf_error != OK:
		return gbnf_error

	var schema: Dictionary[String, Variant] = _build_json_schema(load_result.ids)
	var schema_text: String = JSON.stringify(schema, "\t", false) + "\n"
	return _write_text(output_dir.path_join(SCHEMA_FILE_NAME), schema_text)


static func _parse_cli_arguments(
	arguments: PackedStringArray,
	options: Dictionary[String, String],
) -> Error:
	var index: int = 0
	while index < arguments.size():
		var option: String = arguments[index]
		if option != "--input" and option != "--output":
			printerr("不明な引数です: %s" % option)
			printerr("使用法: --input <skill_tags.json> --output <出力ディレクトリ>")
			return ERR_INVALID_PARAMETER
		if index + 1 >= arguments.size():
			printerr("引数 %s の値がありません。" % option)
			return ERR_INVALID_PARAMETER

		var value: String = arguments[index + 1]
		if value.is_empty():
			printerr("引数 %s に空の値は指定できません。" % option)
			return ERR_INVALID_PARAMETER
		if option == "--input":
			options["input"] = value
		else:
			options["output"] = value
		index += 2
	return OK


static func _load_tag_ids(input_path: String) -> TagLoadResult:
	var result: TagLoadResult = TagLoadResult.new()
	var file: FileAccess = FileAccess.open(input_path, FileAccess.READ)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		printerr(
			"タグタクソノミーを開けません: %s（%s）"
			% [input_path, error_string(open_error)]
		)
		result.error = open_error
		return result

	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	if parse_error != OK:
		printerr(
			"タグタクソノミーのJSON解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		result.error = parse_error
		return result
	if typeof(json.data) != TYPE_ARRAY:
		printerr("タグタクソノミーのルートは配列である必要があります。")
		result.error = ERR_INVALID_DATA
		return result

	var entries: Array = json.data
	if entries.is_empty():
		printerr("タグタクソノミーには1件以上のタグが必要です。")
		result.error = ERR_INVALID_DATA
		return result

	var seen_ids: Dictionary[String, bool] = {}
	for index: int in range(entries.size()):
		var entry_value: Variant = entries[index]
		if typeof(entry_value) != TYPE_DICTIONARY:
			printerr("skill_tags[%d]: JSONオブジェクトである必要があります。" % index)
			result.error = ERR_INVALID_DATA
			return result

		var entry: Dictionary = entry_value
		for field_name: String in REQUIRED_TAG_FIELDS:
			if not entry.has(field_name):
				printerr("skill_tags[%d].%s: 必須項目です。" % [index, field_name])
				result.error = ERR_INVALID_DATA
				return result
			var field_value: Variant = entry[field_name]
			if typeof(field_value) != TYPE_STRING or String(field_value).strip_edges().is_empty():
				printerr(
					"skill_tags[%d].%s: 空でない文字列である必要があります。"
					% [index, field_name]
				)
				result.error = ERR_INVALID_DATA
				return result

		var tag_id: String = entry["id"]
		if seen_ids.has(tag_id):
			printerr("skill_tags[%d].id: タグIDが重複しています: %s" % [index, tag_id])
			result.error = ERR_INVALID_DATA
			return result
		seen_ids[tag_id] = true
		result.ids.append(tag_id)

	return result


static func _build_gbnf(tag_ids: Array[String]) -> String:
	var lines: Array[String] = [
		"# tools/gen_grammar.gd により skill_tags.json から自動生成されます。",
		"# target-enum の右辺は実行時に GameState 由来の許可ID選択肢へ必ず置換します。",
		"# 未置換の番兵値 __TARGET_ENUM_RUNTIME__ を分類に使用してはいけません。",
	]

	var root_symbols: PackedStringArray = PackedStringArray()
	root_symbols.append(_gbnf_literal("{"))
	root_symbols.append("ws")
	_append_json_member(root_symbols, "action_type", "action-type", true)
	_append_json_member(root_symbols, "ability", "ability", true)
	_append_json_member(root_symbols, "skill_tags", "skill-tags", true)
	_append_json_member(root_symbols, "target", "target", true)
	_append_json_member(root_symbols, "difficulty", "difficulty", true)
	_append_json_member(root_symbols, "needs_roll", "needs-roll", true)
	_append_json_member(root_symbols, "summary_ja", "json-string", false)
	root_symbols.append(_gbnf_literal("}"))
	root_symbols.append("ws")

	lines.append("root ::= %s" % " ".join(root_symbols))
	lines.append(_build_enum_rule("action-type", ACTION_TYPES))
	lines.append(_build_enum_rule("ability", ABILITY_IDS))
	lines.append(
		"skill-tags ::= %s ws (skill-tag (ws %s ws skill-tag)?)? ws %s"
		% [_gbnf_literal("["), _gbnf_literal(","), _gbnf_literal("]")]
	)
	lines.append(_build_enum_rule("skill-tag", tag_ids))
	lines.append("target ::= target-enum | %s" % _gbnf_literal("null"))
	lines.append(
		"target-enum ::= %s"
		% _gbnf_literal(JSON.stringify(TARGET_ENUM_PLACEHOLDER))
	)
	lines.append(_build_enum_rule("difficulty", DIFFICULTIES))
	lines.append(
		"needs-roll ::= %s | %s" % [_gbnf_literal("true"), _gbnf_literal("false")]
	)
	lines.append(
		"json-string ::= %s json-char* %s"
		% [_gbnf_literal("\""), _gbnf_literal("\"")]
	)
	lines.append(_build_json_char_rule())

	var backslash: String = String.chr(92)
	lines.append(
		"ws ::= [ " + backslash + "t" + backslash + "n" + backslash + "r]{0,20}"
	)
	return "\n".join(lines) + "\n"


static func _append_json_member(
	symbols: PackedStringArray,
	key: String,
	value_rule: String,
	has_trailing_comma: bool,
) -> void:
	symbols.append(_gbnf_literal(JSON.stringify(key)))
	symbols.append("ws")
	symbols.append(_gbnf_literal(":"))
	symbols.append("ws")
	symbols.append(value_rule)
	symbols.append("ws")
	if has_trailing_comma:
		symbols.append(_gbnf_literal(","))
		symbols.append("ws")


static func _build_enum_rule(rule_name: String, values: Array[String]) -> String:
	var choices: PackedStringArray = PackedStringArray()
	for value: String in values:
		choices.append(_gbnf_literal(JSON.stringify(value)))
	return "%s ::= %s" % [rule_name, " | ".join(choices)]


static func _gbnf_literal(value: String) -> String:
	var escaped: String = value.replace("\\", "\\\\")
	escaped = escaped.replace("\"", "\\\"")
	escaped = escaped.replace("\r", "\\r")
	escaped = escaped.replace("\n", "\\n")
	escaped = escaped.replace("\t", "\\t")
	return "\"%s\"" % escaped


static func _build_json_char_rule() -> String:
	var backslash: String = String.chr(92)
	var unescaped: String = (
		"[^\""
		+ backslash
		+ backslash
		+ backslash
		+ "x7F"
		+ backslash
		+ "x00-"
		+ backslash
		+ "x1F]"
	)
	var escape_prefix: String = "[" + backslash + backslash + "]"
	var escape_codes: String = "[\"" + backslash + backslash + "/bfnrt]"
	return (
		"json-char ::= %s | %s (%s | \"u\" [0-9a-fA-F]{4})"
		% [unescaped, escape_prefix, escape_codes]
	)


static func _build_json_schema(tag_ids: Array[String]) -> Dictionary[String, Variant]:
	return {
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$comment": (
			"target.enum の番兵値は意図分類時に GameState 由来の許可IDへ置換する。"
		),
		"title": "意図分類",
		"type": "object",
		"additionalProperties": false,
		"required": [
			"action_type",
			"ability",
			"skill_tags",
			"target",
			"difficulty",
			"needs_roll",
			"summary_ja",
		],
		"properties": {
			"action_type": {
				"type": "string",
				"enum": ACTION_TYPES.duplicate(),
			},
			"ability": {
				"type": "string",
				"enum": ABILITY_IDS.duplicate(),
			},
			"skill_tags": {
				"type": "array",
				"items": {
					"type": "string",
					"enum": tag_ids.duplicate(),
				},
				"minItems": 0,
				"maxItems": 2,
			},
			"target": {
				"$comment": (
					"enum の番兵値を実行時の target ID 全件へ置換し、null は残す。"
				),
				"type": ["string", "null"],
				"enum": [TARGET_ENUM_PLACEHOLDER, null],
			},
			"difficulty": {
				"type": "string",
				"enum": DIFFICULTIES.duplicate(),
			},
			"needs_roll": {
				"type": "boolean",
			},
			"summary_ja": {
				"type": "string",
			},
		},
	}


static func _write_text(path: String, content: String) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		printerr("生成物を書き込めません: %s（%s）" % [path, error_string(open_error)])
		return open_error

	file.store_string(content)
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		printerr("生成物の書き込みに失敗しました: %s（%s）" % [path, error_string(write_error)])
	return write_error
