class_name CharacterSheet

const TAG_TAXONOMY_PATH: String = "res://game/data/skill_tags.json"
const ABILITY_IDS: Array[String] = ["STR", "DEX", "CON", "INT", "WIS", "CHA"]

var name: String = ""
var description: String = ""
var abilities: Dictionary[String, int] = {
	"STR": 0,
	"DEX": 0,
	"CON": 0,
	"INT": 0,
	"WIS": 0,
	"CHA": 0,
}
var hp: Dictionary[String, int] = {"current": 8, "max": 8}
var skills: Array[String] = []
var specialties: Array[Dictionary] = []
var xp: int = 0
var inventory: Array[Dictionary] = []
var money: int = 0


class LoadResult:
	var sheet: CharacterSheet
	var errors: Array[String]


	func _init(loaded_sheet: CharacterSheet, load_errors: Array[String]) -> void:
		sheet = loaded_sheet
		errors = load_errors.duplicate()


	func is_success() -> bool:
		return sheet != null and errors.is_empty()


static func load(source: Variant, valid_tag_ids: Variant = null) -> LoadResult:
	var errors: Array[String] = []
	var data: Variant = _parse_source(source, errors)
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	errors.append_array(_validate_data(data, valid_tag_ids))
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	var root: Dictionary = data
	return LoadResult.new(_build_sheet(root), errors)


func validate(valid_tag_ids: Variant = null) -> Array[String]:
	return _validate_data(serialize(), valid_tag_ids)


func serialize() -> Dictionary[String, Variant]:
	return {
		"name": name,
		"description": description,
		"abilities": abilities.duplicate(true),
		"hp": hp.duplicate(true),
		"skills": skills.duplicate(),
		"specialties": specialties.duplicate(true),
		"xp": xp,
		"inventory": inventory.duplicate(true),
		"money": money,
	}


static func derive_max_hp(con: int) -> int:
	return 8 + con * 2


static func _parse_source(source: Variant, errors: Array[String]) -> Variant:
	if typeof(source) == TYPE_DICTIONARY:
		var source_dictionary: Dictionary = source
		return source_dictionary.duplicate(true)
	if typeof(source) != TYPE_STRING:
		errors.append("ロード元: JSON文字列またはDictionaryである必要があります。")
		return null

	var json_text: String = source
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(json_text)
	if parse_error != OK:
		errors.append(
			"JSONの解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


static func _validate_data(data: Variant, valid_tag_ids: Variant) -> Array[String]:
	var errors: Array[String] = []
	if typeof(data) != TYPE_DICTIONARY:
		errors.append("ルート: JSONオブジェクトである必要があります。")
		return errors

	var root: Dictionary = data
	var tag_ids: Dictionary[String, bool] = _resolve_tag_ids(valid_tag_ids, errors)
	_validate_required_string(root, "name", "name", errors)
	_validate_required_string(root, "description", "description", errors)
	_validate_abilities(root, errors)
	_validate_hp(root, errors)
	_validate_skills(root, tag_ids, errors)
	_validate_specialties(root, tag_ids, errors)
	_validate_required_integer(root, "xp", "xp", errors)
	_validate_inventory(root, errors)
	_validate_required_integer(root, "money", "money", errors)
	return errors


static func _validate_required_string(
	data: Dictionary,
	key: String,
	path: String,
	errors: Array[String],
) -> void:
	if not data.has(key):
		errors.append("%s: 必須項目です。" % path)
		return
	if typeof(data[key]) != TYPE_STRING:
		errors.append("%s: 文字列である必要があります。" % path)


static func _validate_required_integer(
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


static func _validate_abilities(root: Dictionary, errors: Array[String]) -> void:
	if not root.has("abilities"):
		errors.append("abilities: 必須項目です。")
		return
	if typeof(root["abilities"]) != TYPE_DICTIONARY:
		errors.append("abilities: JSONオブジェクトである必要があります。")
		return

	var raw_abilities: Dictionary = root["abilities"]
	for ability_id: String in ABILITY_IDS:
		var path: String = "abilities.%s" % ability_id
		if not raw_abilities.has(ability_id):
			errors.append("%s: 必須項目です。" % path)
			continue
		var ability_value: Variant = raw_abilities[ability_id]
		if not _is_integer_value(ability_value):
			errors.append("%s: 整数である必要があります。" % path)
			continue
		var ability: int = int(ability_value)
		if ability < Types.ABILITY_MIN or ability > Types.ABILITY_MAX:
			errors.append(
				"%s: %d..%d の範囲外です（値: %d）。"
				% [path, Types.ABILITY_MIN, Types.ABILITY_MAX, ability]
			)


static func _validate_hp(root: Dictionary, errors: Array[String]) -> void:
	if not root.has("hp"):
		errors.append("hp: 必須項目です。")
		return
	if typeof(root["hp"]) != TYPE_DICTIONARY:
		errors.append("hp: JSONオブジェクトである必要があります。")
		return

	var raw_hp: Dictionary = root["hp"]
	_validate_required_integer(raw_hp, "current", "hp.current", errors)
	_validate_required_integer(raw_hp, "max", "hp.max", errors)

	if raw_hp.has("current") and raw_hp.has("max"):
		var current_value: Variant = raw_hp["current"]
		var max_value: Variant = raw_hp["max"]
		if _is_integer_value(current_value) and _is_integer_value(max_value):
			var current_hp: int = int(current_value)
			var max_hp: int = int(max_value)
			if current_hp < 0 or current_hp > max_hp:
				errors.append(
					"hp.current: 0..hp.max の範囲外です（値: %d、hp.max: %d）。"
					% [current_hp, max_hp]
				)

	if not root.has("abilities") or typeof(root["abilities"]) != TYPE_DICTIONARY:
		return
	var raw_abilities: Dictionary = root["abilities"]
	if not raw_abilities.has("CON") or not raw_hp.has("max"):
		return
	var con_value: Variant = raw_abilities["CON"]
	var max_value: Variant = raw_hp["max"]
	if not _is_integer_value(con_value) or not _is_integer_value(max_value):
		return
	var con: int = int(con_value)
	if con < Types.ABILITY_MIN or con > Types.ABILITY_MAX:
		return
	var expected_max: int = derive_max_hp(con)
	var actual_max: int = int(max_value)
	if actual_max != expected_max:
		errors.append(
			"hp.max: CONから導出した値 %d と一致しません（値: %d）。"
			% [expected_max, actual_max]
		)


static func _validate_skills(
	root: Dictionary,
	tag_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not root.has("skills"):
		errors.append("skills: 必須項目です。")
		return
	if typeof(root["skills"]) != TYPE_ARRAY:
		errors.append("skills: 配列である必要があります。")
		return

	var raw_skills: Array = root["skills"]
	for index: int in range(raw_skills.size()):
		_validate_tag_id(raw_skills[index], "skills[%d]" % index, tag_ids, errors)


static func _validate_specialties(
	root: Dictionary,
	tag_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not root.has("specialties"):
		errors.append("specialties: 必須項目です。")
		return
	if typeof(root["specialties"]) != TYPE_ARRAY:
		errors.append("specialties: 配列である必要があります。")
		return

	var raw_specialties: Array = root["specialties"]
	for specialty_index: int in range(raw_specialties.size()):
		var specialty_path: String = "specialties[%d]" % specialty_index
		var specialty_value: Variant = raw_specialties[specialty_index]
		if typeof(specialty_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % specialty_path)
			continue
		var specialty: Dictionary = specialty_value
		_validate_required_string(specialty, "label", "%s.label" % specialty_path, errors)
		if not specialty.has("tags"):
			errors.append("%s.tags: 必須項目です。" % specialty_path)
			continue
		if typeof(specialty["tags"]) != TYPE_ARRAY:
			errors.append("%s.tags: 配列である必要があります。" % specialty_path)
			continue
		var raw_tags: Array = specialty["tags"]
		for tag_index: int in range(raw_tags.size()):
			_validate_tag_id(
				raw_tags[tag_index],
				"%s.tags[%d]" % [specialty_path, tag_index],
				tag_ids,
				errors,
			)


static func _validate_tag_id(
	value: Variant,
	path: String,
	tag_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if typeof(value) != TYPE_STRING:
		errors.append("%s: タグIDは文字列である必要があります。" % path)
		return
	var tag_id: String = value
	if not tag_ids.has(tag_id):
		errors.append("%s: タクソノミーに存在しないタグIDです: %s" % [path, tag_id])


static func _validate_inventory(root: Dictionary, errors: Array[String]) -> void:
	if not root.has("inventory"):
		errors.append("inventory: 必須項目です。")
		return
	if typeof(root["inventory"]) != TYPE_ARRAY:
		errors.append("inventory: 配列である必要があります。")
		return

	var raw_inventory: Array = root["inventory"]
	for index: int in range(raw_inventory.size()):
		var item_path: String = "inventory[%d]" % index
		var item_value: Variant = raw_inventory[index]
		if typeof(item_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % item_path)
			continue
		var item: Dictionary = item_value
		_validate_required_string(item, "item_id", "%s.item_id" % item_path, errors)
		_validate_required_integer(item, "count", "%s.count" % item_path, errors)


static func _resolve_tag_ids(
	valid_tag_ids: Variant,
	errors: Array[String],
) -> Dictionary[String, bool]:
	if valid_tag_ids == null:
		return _load_default_tag_ids(errors)
	if typeof(valid_tag_ids) != TYPE_DICTIONARY:
		errors.append("タグID集合: Dictionaryである必要があります。")
		return {}

	var resolved: Dictionary[String, bool] = {}
	var provided: Dictionary = valid_tag_ids
	for key: Variant in provided.keys():
		if typeof(key) != TYPE_STRING:
			errors.append("タグID集合: キーは文字列である必要があります。")
			continue
		var tag_id: String = key
		resolved[tag_id] = true
	return resolved


static func _load_default_tag_ids(errors: Array[String]) -> Dictionary[String, bool]:
	var tag_ids: Dictionary[String, bool] = {}
	var file: FileAccess = FileAccess.open(TAG_TAXONOMY_PATH, FileAccess.READ)
	if file == null:
		var open_error: Error = FileAccess.get_open_error()
		errors.append(
			"タグタクソノミーを開けません: %s（%s）"
			% [TAG_TAXONOMY_PATH, error_string(open_error)]
		)
		return tag_ids

	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	if parse_error != OK:
		errors.append(
			"タグタクソノミーのJSON解析に失敗しました（行%d）: %s"
			% [json.get_error_line(), json.get_error_message()]
		)
		return tag_ids
	if typeof(json.data) != TYPE_ARRAY:
		errors.append("タグタクソノミー: ルートは配列である必要があります。")
		return tag_ids

	var entries: Array = json.data
	for index: int in range(entries.size()):
		var path: String = "skill_tags[%d]" % index
		var entry_value: Variant = entries[index]
		if typeof(entry_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var entry: Dictionary = entry_value
		_validate_required_string(entry, "id", "%s.id" % path, errors)
		_validate_required_string(entry, "label_ja", "%s.label_ja" % path, errors)
		_validate_required_string(entry, "hint_ja", "%s.hint_ja" % path, errors)
		if not entry.has("id") or typeof(entry["id"]) != TYPE_STRING:
			continue
		var tag_id: String = entry["id"]
		if tag_id.is_empty():
			errors.append("%s.id: 空文字列は使用できません。" % path)
			continue
		if tag_ids.has(tag_id):
			errors.append("%s.id: タグIDが重複しています: %s" % [path, tag_id])
			continue
		tag_ids[tag_id] = true
	return tag_ids


static func _is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var float_value: float = value
	return is_finite(float_value) and float_value == floor(float_value)


static func _build_sheet(data: Dictionary) -> CharacterSheet:
	var sheet: CharacterSheet = CharacterSheet.new()
	sheet.name = String(data["name"])
	sheet.description = String(data["description"])

	var raw_abilities: Dictionary = data["abilities"]
	for ability_id: String in ABILITY_IDS:
		sheet.abilities[ability_id] = int(raw_abilities[ability_id])

	var raw_hp: Dictionary = data["hp"]
	sheet.hp["current"] = int(raw_hp["current"])
	sheet.hp["max"] = int(raw_hp["max"])

	sheet.skills.clear()
	var raw_skills: Array = data["skills"]
	for skill_value: Variant in raw_skills:
		sheet.skills.append(String(skill_value))

	sheet.specialties.clear()
	var raw_specialties: Array = data["specialties"]
	for specialty_value: Variant in raw_specialties:
		var raw_specialty: Dictionary = specialty_value
		var tags: Array[String] = []
		var raw_tags: Array = raw_specialty["tags"]
		for tag_value: Variant in raw_tags:
			tags.append(String(tag_value))
		sheet.specialties.append(
			{
				"label": String(raw_specialty["label"]),
				"tags": tags,
			}
		)

	sheet.xp = int(data["xp"])
	sheet.inventory.clear()
	var raw_inventory: Array = data["inventory"]
	for item_value: Variant in raw_inventory:
		var raw_item: Dictionary = item_value
		sheet.inventory.append(
			{
				"item_id": String(raw_item["item_id"]),
				"count": int(raw_item["count"]),
			}
		)
	sheet.money = int(data["money"])
	return sheet
