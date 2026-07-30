class_name ItemRegistry

const ITEMS_PATH: String = "res://game/data/items.json"

static var _default_cache: Dictionary[String, Dictionary] = {}


class LoadResult:
	var items: Dictionary[String, Dictionary] = {}
	var errors: Array[String] = []


	func _init(
		loaded_items: Dictionary[String, Dictionary] = {},
		load_errors: Array[String] = [],
	) -> void:
		items = loaded_items.duplicate(true)
		errors = load_errors.duplicate()


	func is_success() -> bool:
		return errors.is_empty()


static func load(
	scenario: Scenario,
	source: Variant = null,
) -> LoadResult:
	if source != null:
		return _load_source(source, scenario)
	var cache_key: String = JSON.stringify(scenario.serialize(), "", true)
	if _default_cache.has(cache_key):
		var cached: Dictionary = _default_cache[cache_key]
		return LoadResult.new(cached["items"], cached["errors"])

	var errors: Array[String] = []
	var file: FileAccess = FileAccess.open(ITEMS_PATH, FileAccess.READ)
	if file == null:
		errors.append(
			"アイテムデータを開けません: %s（%s）"
			% [ITEMS_PATH, error_string(FileAccess.get_open_error())]
		)
		_default_cache[cache_key] = {"items": {}, "errors": errors.duplicate()}
		return LoadResult.new({}, errors)
	var result: LoadResult = _load_source(file.get_as_text(), scenario)
	_default_cache[cache_key] = {
		"items": result.items.duplicate(true),
		"errors": result.errors.duplicate(),
	}
	return result


static func _load_source(source: Variant, scenario: Scenario) -> LoadResult:
	var errors: Array[String] = []
	var parsed: Variant = _parse_source(source, errors)
	if not errors.is_empty():
		return LoadResult.new({}, errors)
	var entries: Array = []
	if typeof(parsed) == TYPE_ARRAY:
		entries = parsed
	elif typeof(parsed) == TYPE_DICTIONARY:
		var root: Dictionary = parsed
		if root.has("items") and typeof(root["items"]) == TYPE_ARRAY:
			entries = root["items"]
		else:
			errors.append("アイテムデータのルートには items 配列が必要です。")
			return LoadResult.new({}, errors)
	else:
		errors.append("アイテムデータのルートは配列またはJSONオブジェクトである必要があります。")
		return LoadResult.new({}, errors)

	var items: Dictionary[String, Dictionary] = {}
	for index: int in range(entries.size()):
		var path: String = "items[%d]" % index
		var value: Variant = entries[index]
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var item: Dictionary = value
		var error_count_before: int = errors.size()
		if not _has_non_empty_string(item, "id"):
			errors.append("%s.id: 空でない文字列が必要です。" % path)
		if not _has_non_empty_string(item, "name_ja"):
			errors.append("%s.name_ja: 空でない文字列が必要です。" % path)
		var item_id: String = String(item.get("id", ""))
		if not item_id.is_empty() and items.has(item_id):
			errors.append("%s.id: アイテムIDが重複しています: %s" % [path, item_id])
		if item.has("damage") and (
			not _is_integer_value(item["damage"])
			or int(item["damage"]) <= 0
		):
			errors.append("%s.damage: 1以上の整数である必要があります。" % path)
		if item.has("effect"):
			if typeof(item["effect"]) != TYPE_DICTIONARY:
				errors.append("%s.effect: JSONオブジェクトである必要があります。" % path)
			else:
				var effect: Dictionary = item["effect"]
				var effect_errors: Array[String] = scenario.apply_effect(
					effect,
					GameState.new(),
				)
				for effect_error: String in effect_errors:
					errors.append("%s.%s" % [path, effect_error])
		if errors.size() == error_count_before:
			items[item_id] = item.duplicate(true)
	return LoadResult.new(items, errors)


static func _parse_source(source: Variant, errors: Array[String]) -> Variant:
	if typeof(source) in [TYPE_DICTIONARY, TYPE_ARRAY]:
		return source.duplicate(true)
	if typeof(source) != TYPE_STRING:
		errors.append("アイテムデータはJSON文字列、Dictionary、Array のいずれかである必要があります。")
		return null
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(String(source))
	if parse_error != OK:
		errors.append(
			"アイテムデータのJSON解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


static func _has_non_empty_string(data: Dictionary, key: String) -> bool:
	return (
		data.has(key)
		and typeof(data[key]) == TYPE_STRING
		and not String(data[key]).is_empty()
	)


static func _is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var float_value: float = value
	return is_finite(float_value) and float_value == floor(float_value)
