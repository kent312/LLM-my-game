extends GutTest

const GrammarGenerator: GDScript = preload("res://tools/gen_grammar.gd")

const TAXONOMY_PATH: String = "res://game/data/skill_tags.json"
const GENERATED_GBNF_PATH: String = "res://game/data/generated/intent.gbnf"
const GENERATED_SCHEMA_PATH: String = "res://game/data/generated/intent_schema.json"
const TEMP_ROOT: String = "user://test_grammar_gen"
const TEMP_INPUT_PATH: String = TEMP_ROOT + "/skill_tags.json"
const TEMP_OUTPUT_DIR: String = TEMP_ROOT + "/generated"
const ADDED_TAG_ID: String = "test.extra"


func before_each() -> void:
	_cleanup_temp_files()


func after_each() -> void:
	_cleanup_temp_files()


func test_generated_gbnf_contains_all_24_tag_ids() -> void:
	var entries: Array = _load_taxonomy_entries()
	var expected_ids: Array[String] = _extract_tag_ids(entries)
	var gbnf: String = _read_text(GENERATED_GBNF_PATH)

	assert_eq(expected_ids.size(), 24, "正式タクソノミーは24タグである必要があります。")
	for tag_id: String in expected_ids:
		assert_true(gbnf.contains(tag_id), "GBNFにタグIDがありません: %s" % tag_id)
	assert_true(
		gbnf.contains("skill-tags ::= \"[\" ws (skill-tag (ws \",\" ws skill-tag)?)? ws \"]\""),
		"skill_tags配列を0〜2件に制限する規則がありません。",
	)
	assert_true(
		gbnf.contains(GrammarGenerator.TARGET_ENUM_PLACEHOLDER),
		"targetの実行時置換用プレースホルダがありません。",
	)


func test_schema_skill_tag_enum_matches_taxonomy() -> void:
	var entries: Array = _load_taxonomy_entries()
	var expected_ids: Array[String] = _extract_tag_ids(entries)
	var schema_value: Variant = _read_json(GENERATED_SCHEMA_PATH)
	if typeof(schema_value) != TYPE_DICTIONARY:
		fail_test("生成されたJSONスキーマのルートがオブジェクトではありません。")
		return

	var schema: Dictionary = schema_value
	var skill_tags: Dictionary = _schema_property(schema, "skill_tags")
	if skill_tags.is_empty():
		return
	var actual_ids: Array[String] = _schema_skill_tag_ids(skill_tags)

	assert_eq(actual_ids, expected_ids, "JSONスキーマのタグenumがタクソノミーと一致しません。")
	assert_eq(int(skill_tags.get("minItems", -1)), 0)
	assert_eq(int(skill_tags.get("maxItems", -1)), 2)
	assert_eq(schema.get("additionalProperties"), false)

	var target: Dictionary = _schema_property(schema, "target")
	if target.is_empty():
		return
	var target_enum_value: Variant = target.get("enum")
	assert_eq(typeof(target_enum_value), TYPE_ARRAY, "target.enumは配列である必要があります。")
	if typeof(target_enum_value) != TYPE_ARRAY:
		return
	var target_enum: Array = target_enum_value
	assert_true(target_enum.has(GrammarGenerator.TARGET_ENUM_PLACEHOLDER))
	assert_true(target_enum.has(null))


func test_added_tag_is_reflected_in_both_outputs() -> void:
	var entries: Array = _load_taxonomy_entries().duplicate(true)
	entries.append(
		{
			"id": ADDED_TAG_ID,
			"label_ja": "追加テスト",
			"hint_ja": "生成器への追随を確認するためのテスト用タグ",
		}
	)

	var directory_error: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(TEMP_ROOT)
	)
	assert_eq(directory_error, OK, "一時ディレクトリを作成できません。")
	if directory_error != OK:
		return
	var input_error: Error = _write_text(
		TEMP_INPUT_PATH,
		JSON.stringify(entries, "\t", false) + "\n",
	)
	assert_eq(input_error, OK, "一時タクソノミーを書き込めません。")
	if input_error != OK:
		return

	var generation_error: Error = GrammarGenerator.generate(TEMP_INPUT_PATH, TEMP_OUTPUT_DIR)
	assert_eq(generation_error, OK, "一時タクソノミーからの生成に失敗しました。")
	if generation_error != OK:
		return

	var gbnf_path: String = TEMP_OUTPUT_DIR.path_join(GrammarGenerator.GBNF_FILE_NAME)
	var schema_path: String = TEMP_OUTPUT_DIR.path_join(GrammarGenerator.SCHEMA_FILE_NAME)
	var gbnf: String = _read_text(gbnf_path)
	assert_true(gbnf.contains(ADDED_TAG_ID), "追加タグがGBNFに反映されていません。")

	var schema_value: Variant = _read_json(schema_path)
	if typeof(schema_value) != TYPE_DICTIONARY:
		fail_test("一時生成したJSONスキーマのルートがオブジェクトではありません。")
		return
	var schema: Dictionary = schema_value
	var skill_tags: Dictionary = _schema_property(schema, "skill_tags")
	if skill_tags.is_empty():
		return
	var actual_ids: Array[String] = _schema_skill_tag_ids(skill_tags)
	assert_true(actual_ids.has(ADDED_TAG_ID), "追加タグがJSONスキーマに反映されていません。")


func _load_taxonomy_entries() -> Array:
	var data: Variant = _read_json(TAXONOMY_PATH)
	if typeof(data) != TYPE_ARRAY:
		fail_test("タグタクソノミーのルートが配列ではありません。")
		return []
	return data


func _extract_tag_ids(entries: Array) -> Array[String]:
	var ids: Array[String] = []
	for index: int in range(entries.size()):
		var entry_value: Variant = entries[index]
		if typeof(entry_value) != TYPE_DICTIONARY:
			fail_test("skill_tags[%d] がオブジェクトではありません。" % index)
			return []
		var entry: Dictionary = entry_value
		if not entry.has("id") or typeof(entry["id"]) != TYPE_STRING:
			fail_test("skill_tags[%d].id が文字列ではありません。" % index)
			return []
		ids.append(String(entry["id"]))
	return ids


func _schema_property(schema: Dictionary, property_name: String) -> Dictionary:
	var properties_value: Variant = schema.get("properties")
	if typeof(properties_value) != TYPE_DICTIONARY:
		fail_test("JSONスキーマにpropertiesオブジェクトがありません。")
		return {}
	var properties: Dictionary = properties_value
	if not properties.has(property_name):
		fail_test("JSONスキーマに%sプロパティがありません。" % property_name)
		return {}
	var property_value: Variant = properties[property_name]
	if typeof(property_value) != TYPE_DICTIONARY:
		fail_test("JSONスキーマの%sがオブジェクトではありません。" % property_name)
		return {}
	return property_value


func _schema_skill_tag_ids(skill_tags: Dictionary) -> Array[String]:
	var items_value: Variant = skill_tags.get("items")
	if typeof(items_value) != TYPE_DICTIONARY:
		fail_test("skill_tags.itemsがオブジェクトではありません。")
		return []
	var items: Dictionary = items_value
	var enum_value: Variant = items.get("enum")
	if typeof(enum_value) != TYPE_ARRAY:
		fail_test("skill_tags.items.enumが配列ではありません。")
		return []

	var ids: Array[String] = []
	var raw_ids: Array = enum_value
	for index: int in range(raw_ids.size()):
		var id_value: Variant = raw_ids[index]
		if typeof(id_value) != TYPE_STRING:
			fail_test("skill_tags.items.enum[%d]が文字列ではありません。" % index)
			return []
		ids.append(String(id_value))
	return ids


func _read_json(path: String) -> Variant:
	var text: String = _read_text(path)
	if text.is_empty():
		return null
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(text)
	if parse_error != OK:
		fail_test(
			"JSONの解析に失敗しました（%s、行%d）: %s"
			% [path, json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		fail_test("ファイルを開けません: %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return ""
	return file.get_as_text()


func _write_text(path: String, content: String) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(content)
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	return write_error


func _cleanup_temp_files() -> void:
	var user_dir: DirAccess = DirAccess.open("user://")
	if user_dir == null:
		return
	user_dir.remove("test_grammar_gen/generated/intent.gbnf")
	user_dir.remove("test_grammar_gen/generated/intent_schema.json")
	user_dir.remove("test_grammar_gen/generated")
	user_dir.remove("test_grammar_gen/skill_tags.json")
	user_dir.remove("test_grammar_gen")
