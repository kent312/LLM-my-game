class_name GameState

var character: CharacterSheet = CharacterSheet.new()
var scenario_id: String = ""
var scene_id: String = ""
var flags: Dictionary = {}
var active_enemies: Array[Dictionary] = []
var clock: int = 0
var turn_count: int = 0
var pending_narration: Variant = null


class LoadResult:
	var state: GameState
	var errors: Array[String]


	func _init(loaded_state: GameState, load_errors: Array[String]) -> void:
		state = loaded_state
		errors = load_errors.duplicate()


	func is_success() -> bool:
		return state != null and errors.is_empty()


func serialize() -> Dictionary[String, Variant]:
	return {
		"character": character.serialize(),
		"scenario_id": scenario_id,
		"scene_id": scene_id,
		"flags": flags.duplicate(true),
		"active_enemies": active_enemies.duplicate(true),
		"clock": clock,
		"turn_count": turn_count,
		"pending_narration": _duplicate_variant(pending_narration),
	}


static func deserialize(source: Variant) -> LoadResult:
	var errors: Array[String] = []
	var data: Variant = _parse_source(source, errors)
	if not errors.is_empty():
		return LoadResult.new(null, errors)
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("ルート: JSONオブジェクトである必要があります。")
		return LoadResult.new(null, errors)

	var root: Dictionary = data
	_validate_required_type(root, "character", TYPE_DICTIONARY, "character", errors)
	_validate_required_type(root, "scenario_id", TYPE_STRING, "scenario_id", errors)
	_validate_required_type(root, "scene_id", TYPE_STRING, "scene_id", errors)
	_validate_flags(root, errors)
	_validate_active_enemies(root, errors)
	_validate_non_negative_integer(root, "clock", "clock", errors)
	_validate_non_negative_integer(root, "turn_count", "turn_count", errors)
	if not root.has("pending_narration"):
		errors.append("pending_narration: 必須項目です。")

	var character_result: CharacterSheet.LoadResult = CharacterSheet.LoadResult.new(null, [])
	if root.has("character") and typeof(root["character"]) == TYPE_DICTIONARY:
		character_result = CharacterSheet.load(root["character"])
		for character_error: String in character_result.errors:
			errors.append("character.%s" % character_error)
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	var state: GameState = GameState.new()
	state.character = character_result.sheet
	state.scenario_id = String(root["scenario_id"])
	state.scene_id = String(root["scene_id"])
	var raw_flags: Dictionary = root["flags"]
	state.flags.clear()
	for flag_key_value: Variant in raw_flags.keys():
		var flag_key: String = flag_key_value
		var flag_value: Variant = raw_flags[flag_key]
		state.flags[flag_key] = int(flag_value) if _is_integer_value(flag_value) else flag_value
	state.active_enemies.clear()
	var raw_enemies: Array = root["active_enemies"]
	for enemy_value: Variant in raw_enemies:
		var enemy: Dictionary = enemy_value
		var enemy_hp: Dictionary = enemy["hp"]
		state.active_enemies.append(
			{
				"enemy_id": String(enemy["enemy_id"]),
				"hp": {
					"current": int(enemy_hp["current"]),
					"max": int(enemy_hp["max"]),
				},
			}
		)
	state.clock = int(root["clock"])
	state.turn_count = int(root["turn_count"])
	state.pending_narration = root["pending_narration"]
	return LoadResult.new(state, errors)


static func _parse_source(source: Variant, errors: Array[String]) -> Variant:
	if typeof(source) == TYPE_DICTIONARY:
		var source_dictionary: Dictionary = source
		return source_dictionary.duplicate(true)
	if typeof(source) != TYPE_STRING:
		errors.append("ロード元: JSON文字列またはDictionaryである必要があります。")
		return null
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(String(source))
	if parse_error != OK:
		errors.append(
			"JSONの解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


static func _validate_flags(root: Dictionary, errors: Array[String]) -> void:
	if not _validate_required_type(root, "flags", TYPE_DICTIONARY, "flags", errors):
		return
	var raw_flags: Dictionary = root["flags"]
	for key_value: Variant in raw_flags.keys():
		if typeof(key_value) != TYPE_STRING:
			errors.append("flags: キーは文字列である必要があります。")
			continue
		var flag_name: String = key_value
		var flag_value: Variant = raw_flags[flag_name]
		if not _is_flag_value(flag_value):
			errors.append("flags.%s: bool、int、string のいずれかである必要があります。" % flag_name)


static func _validate_active_enemies(root: Dictionary, errors: Array[String]) -> void:
	if not _validate_required_type(root, "active_enemies", TYPE_ARRAY, "active_enemies", errors):
		return
	var enemies: Array = root["active_enemies"]
	for index: int in range(enemies.size()):
		var path: String = "active_enemies[%d]" % index
		var enemy_value: Variant = enemies[index]
		if typeof(enemy_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var enemy: Dictionary = enemy_value
		_validate_required_type(enemy, "enemy_id", TYPE_STRING, "%s.enemy_id" % path, errors)
		if not _validate_required_type(enemy, "hp", TYPE_DICTIONARY, "%s.hp" % path, errors):
			continue
		var hp: Dictionary = enemy["hp"]
		_validate_non_negative_integer(hp, "current", "%s.hp.current" % path, errors)
		_validate_non_negative_integer(hp, "max", "%s.hp.max" % path, errors)
		if _has_integer(hp, "current") and _has_integer(hp, "max"):
			if int(hp["current"]) > int(hp["max"]):
				errors.append("%s.hp.current: hp.max を超えることはできません。" % path)


static func _validate_required_type(
	data: Dictionary,
	key: String,
	expected_type: int,
	path: String,
	errors: Array[String],
) -> bool:
	if not data.has(key):
		errors.append("%s: 必須項目です。" % path)
		return false
	if typeof(data[key]) != expected_type:
		errors.append("%s: 型が不正です。" % path)
		return false
	return true


static func _validate_non_negative_integer(
	data: Dictionary,
	key: String,
	path: String,
	errors: Array[String],
) -> void:
	if not data.has(key):
		errors.append("%s: 必須項目です。" % path)
		return
	if not _is_integer_value(data[key]):
		errors.append("%s: 整数である必要があります。" % path)
		return
	if int(data[key]) < 0:
		errors.append("%s: 0以上である必要があります。" % path)


static func _has_integer(data: Dictionary, key: String) -> bool:
	return data.has(key) and _is_integer_value(data[key])


static func _is_flag_value(value: Variant) -> bool:
	return typeof(value) in [TYPE_BOOL, TYPE_STRING] or _is_integer_value(value)


static func _is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var float_value: float = value
	return is_finite(float_value) and float_value == floor(float_value)


static func _duplicate_variant(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary_value: Dictionary = value
		return dictionary_value.duplicate(true)
	if typeof(value) == TYPE_ARRAY:
		var array_value: Array = value
		return array_value.duplicate(true)
	return value
