class_name Scenario

const ENEMIES_PATH: String = "res://game/data/enemies.json"
const EFFECT_NAMES: Array[String] = [
	"set_flags",
	"add_item",
	"remove_item",
	"damage",
	"heal",
	"advance_clock",
	"goto",
]

var data: Dictionary = {}


class LoadResult:
	var scenario: Scenario
	var errors: Array[String]


	func _init(loaded_scenario: Scenario, load_errors: Array[String]) -> void:
		scenario = loaded_scenario
		errors = load_errors.duplicate()


	func is_success() -> bool:
		return scenario != null and errors.is_empty()


class ConditionResult:
	var value: bool = false
	var errors: Array[String] = []


	func _init(evaluated_value: bool, evaluation_errors: Array[String]) -> void:
		value = evaluated_value
		errors = evaluation_errors.duplicate()


	func is_success() -> bool:
		return errors.is_empty()


static func load(source: Variant, enemies_source: Variant = null) -> LoadResult:
	var errors: Array[String] = []
	var scenario_data: Variant = _parse_source(source, "シナリオ", errors)
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	var resolved_enemies_source: Variant = enemies_source
	if resolved_enemies_source == null:
		resolved_enemies_source = _read_file(ENEMIES_PATH, "敵データ", errors)
	var enemies_data: Variant = _parse_source(resolved_enemies_source, "敵データ", errors)
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	errors.append_array(_validate_data(scenario_data, enemies_data))
	if not errors.is_empty():
		return LoadResult.new(null, errors)

	var loaded: Scenario = Scenario.new()
	var root: Dictionary = scenario_data
	loaded.data = root.duplicate(true)
	return LoadResult.new(loaded, errors)


static func load_file(path: String, enemies_path: String = ENEMIES_PATH) -> LoadResult:
	var errors: Array[String] = []
	var scenario_text: Variant = _read_file(path, "シナリオ", errors)
	var enemies_text: Variant = _read_file(enemies_path, "敵データ", errors)
	if not errors.is_empty():
		return LoadResult.new(null, errors)
	return Scenario.load(scenario_text, enemies_text)


func serialize() -> Dictionary:
	return data.duplicate(true)


func apply_effect(effect: Dictionary, state: GameState) -> Array[String]:
	var errors: Array[String] = []
	var scene_ids: Dictionary[String, bool] = _collect_scene_ids(data, errors)
	_validate_effect(effect, "effect", scene_ids, errors)
	if not errors.is_empty():
		return errors

	# 検証後に閉じた語彙だけを適用する。動的呼び出しや式評価は行わない（ARCH-3）。
	for effect_name: String in EFFECT_NAMES:
		if not effect.has(effect_name):
			continue
		var effect_value: Variant = effect[effect_name]
		match effect_name:
			"set_flags":
				_apply_set_flags(effect_value, state)
			"add_item":
				_apply_add_item(effect_value, state)
			"remove_item":
				_apply_remove_item(effect_value, state)
			"damage":
				state.character.hp["current"] = maxi(
					0,
					int(state.character.hp["current"]) - int(effect_value),
				)
			"heal":
				state.character.hp["current"] = mini(
					int(state.character.hp["max"]),
					int(state.character.hp["current"]) + int(effect_value),
				)
			"advance_clock":
				state.clock += int(effect_value)
			"goto":
				state.scene_id = String(effect_value)
			_:
				# EFFECT_NAMES と match の不整合はプログラム不変条件違反として停止する。
				assert(false, "effect 適用器に未実装の語彙があります: %s" % effect_name)
	return errors


static func evaluate_condition(condition: String, state: GameState) -> ConditionResult:
	var errors: Array[String] = validate_condition(condition, "condition")
	if not errors.is_empty():
		return ConditionResult.new(false, errors)
	if condition.begins_with("flag:"):
		var flag_name: String = condition.trim_prefix("flag:")
		return ConditionResult.new(_is_truthy(state.flags.get(flag_name)), errors)
	var threshold_text: String = condition.trim_prefix("clock:")
	return ConditionResult.new(state.clock >= int(threshold_text), errors)


static func validate_condition(condition: String, path: String = "condition") -> Array[String]:
	var errors: Array[String] = []
	if condition.begins_with("flag:"):
		if condition.trim_prefix("flag:").is_empty():
			errors.append("%s: flag 名が空です。" % path)
		return errors
	if condition.begins_with("clock:"):
		var threshold_text: String = condition.trim_prefix("clock:")
		if not threshold_text.is_valid_int() or int(threshold_text) < 0:
			errors.append("%s: clock は0以上の整数で指定してください。" % path)
		return errors
	errors.append("%s: 未知の condition 構文です: %s" % [path, condition])
	return errors


func grant_rewards(state: GameState) -> Array[String]:
	var errors: Array[String] = []
	if not data.has("rewards") or typeof(data["rewards"]) != TYPE_DICTIONARY:
		errors.append("rewards: JSONオブジェクトである必要があります。")
		return errors
	var rewards: Dictionary = data["rewards"]
	_validate_non_negative_integer(rewards, "xp", "rewards.xp", errors)
	_validate_non_negative_integer(rewards, "money", "rewards.money", errors)
	if not errors.is_empty():
		return errors
	state.character.xp += int(rewards["xp"])
	state.character.money += int(rewards["money"])
	return errors


static func _validate_data(scenario_data: Variant, enemies_data: Variant) -> Array[String]:
	var errors: Array[String] = []
	var enemy_ids: Dictionary[String, bool] = _validate_enemies(enemies_data, errors)
	if typeof(scenario_data) != TYPE_DICTIONARY:
		errors.append("シナリオのルート: JSONオブジェクトである必要があります。")
		return errors
	var root: Dictionary = scenario_data
	_validate_required_string(root, "id", "id", errors)
	_validate_required_string(root, "title", "title", errors)
	_validate_non_negative_integer(root, "estimated_minutes", "estimated_minutes", errors)
	_validate_required_string(root, "intro_ja", "intro_ja", errors)
	if not root.has("on_defeat"):
		errors.append("on_defeat: 必須項目です。")
	elif typeof(root["on_defeat"]) != TYPE_DICTIONARY:
		errors.append("on_defeat: JSONオブジェクトである必要があります。")
	_validate_rewards(root, errors)

	if not root.has("scenes"):
		errors.append("scenes: 必須項目です。")
		return errors
	if typeof(root["scenes"]) != TYPE_ARRAY:
		errors.append("scenes: 配列である必要があります。")
		return errors
	var scene_ids: Dictionary[String, bool] = _collect_scene_ids(root, errors)
	var scenes: Array = root["scenes"]
	for scene_index: int in range(scenes.size()):
		_validate_scene(scenes[scene_index], scene_index, scene_ids, enemy_ids, errors)
	_validate_enemy_references(root.get("enemies_ref", []), "enemies_ref", enemy_ids, errors)
	if root.has("on_defeat") and typeof(root["on_defeat"]) == TYPE_DICTIONARY:
		var on_defeat: Dictionary = root["on_defeat"]
		_validate_effect(on_defeat, "on_defeat", scene_ids, errors)
	return errors


static func _validate_scene(
	scene_value: Variant,
	scene_index: int,
	scene_ids: Dictionary[String, bool],
	enemy_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	var path: String = "scenes[%d]" % scene_index
	if typeof(scene_value) != TYPE_DICTIONARY:
		errors.append("%s: JSONオブジェクトである必要があります。" % path)
		return
	var scene: Dictionary = scene_value
	_validate_required_string(scene, "id", "%s.id" % path, errors)
	_validate_required_string(scene, "goal_ja", "%s.goal_ja" % path, errors)
	_validate_string_array(scene, "mood_tags", "%s.mood_tags" % path, false, errors)
	_validate_checks(scene, path, scene_ids, errors)
	_validate_complications(scene, path, scene_ids, errors)
	_validate_exits(scene, path, scene_ids, errors)
	if scene.has("enemies"):
		_validate_enemy_references(scene["enemies"], "%s.enemies" % path, enemy_ids, errors)


static func _validate_checks(
	scene: Dictionary,
	scene_path: String,
	scene_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not scene.has("checks"):
		return
	if typeof(scene["checks"]) != TYPE_ARRAY:
		errors.append("%s.checks: 配列である必要があります。" % scene_path)
		return
	var seen_check_ids: Dictionary[String, bool] = {}
	var checks: Array = scene["checks"]
	for check_index: int in range(checks.size()):
		var path: String = "%s.checks[%d]" % [scene_path, check_index]
		var check_value: Variant = checks[check_index]
		if typeof(check_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var check: Dictionary = check_value
		if _validate_required_string(check, "id", "%s.id" % path, errors):
			var check_id: String = check["id"]
			if seen_check_ids.has(check_id):
				errors.append("%s.id: シーン内で check ID が重複しています: %s" % [path, check_id])
			else:
				seen_check_ids[check_id] = true
		_validate_required_string(check, "trigger_hint", "%s.trigger_hint" % path, errors)
		_validate_required_string(check, "ability", "%s.ability" % path, errors)
		if check.has("situation_mod") and not _is_integer_value(check["situation_mod"]):
			errors.append("%s.situation_mod: 整数である必要があります。" % path)
		for branch_name: String in ["on_success", "on_partial", "on_failure"]:
			if not check.has(branch_name):
				continue
			var branch_value: Variant = check[branch_name]
			if typeof(branch_value) != TYPE_DICTIONARY:
				errors.append("%s.%s: JSONオブジェクトである必要があります。" % [path, branch_name])
				continue
			var branch: Dictionary = branch_value
			_validate_effect(branch, "%s.%s" % [path, branch_name], scene_ids, errors, true)


static func _validate_complications(
	scene: Dictionary,
	scene_path: String,
	scene_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not scene.has("complications"):
		return
	if typeof(scene["complications"]) != TYPE_ARRAY:
		errors.append("%s.complications: 配列である必要があります。" % scene_path)
		return
	var complications: Array = scene["complications"]
	for index: int in range(complications.size()):
		var path: String = "%s.complications[%d]" % [scene_path, index]
		var value: Variant = complications[index]
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var complication: Dictionary = value
		_validate_required_string(complication, "id", "%s.id" % path, errors)
		_validate_required_string(complication, "hint_ja", "%s.hint_ja" % path, errors)
		if not complication.has("effect") or typeof(complication["effect"]) != TYPE_DICTIONARY:
			errors.append("%s.effect: JSONオブジェクトである必要があります。" % path)
			continue
		var effect: Dictionary = complication["effect"]
		_validate_effect(effect, "%s.effect" % path, scene_ids, errors)


static func _validate_exits(
	scene: Dictionary,
	scene_path: String,
	scene_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not scene.has("exits"):
		return
	if typeof(scene["exits"]) != TYPE_ARRAY:
		errors.append("%s.exits: 配列である必要があります。" % scene_path)
		return
	var exits: Array = scene["exits"]
	for index: int in range(exits.size()):
		var path: String = "%s.exits[%d]" % [scene_path, index]
		var exit_value: Variant = exits[index]
		if typeof(exit_value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var exit_data: Dictionary = exit_value
		if _validate_required_string(exit_data, "goto", "%s.goto" % path, errors):
			_validate_scene_reference(String(exit_data["goto"]), "%s.goto" % path, scene_ids, errors)
		if exit_data.has("condition"):
			if typeof(exit_data["condition"]) != TYPE_STRING:
				errors.append("%s.condition: 文字列である必要があります。" % path)
			else:
				errors.append_array(validate_condition(String(exit_data["condition"]), "%s.condition" % path))


static func _validate_effect(
	effect: Dictionary,
	path: String,
	scene_ids: Dictionary[String, bool],
	errors: Array[String],
	allow_complication: bool = false,
) -> void:
	for key_value: Variant in effect.keys():
		if typeof(key_value) != TYPE_STRING:
			errors.append("%s: effect 名は文字列である必要があります。" % path)
			continue
		var effect_name: String = key_value
		if allow_complication and effect_name == "complication":
			if typeof(effect[effect_name]) != TYPE_STRING:
				errors.append("%s.complication: 文字列である必要があります。" % path)
			continue
		if not EFFECT_NAMES.has(effect_name):
			errors.append("%s.%s: 未知の effect 名です。" % [path, effect_name])
			continue
		var value: Variant = effect[effect_name]
		match effect_name:
			"set_flags":
				_validate_flag_effect(value, "%s.set_flags" % path, errors)
			"add_item", "remove_item":
				_validate_item_effect(value, "%s.%s" % [path, effect_name], errors)
			"damage", "heal", "advance_clock":
				if not _is_integer_value(value) or int(value) < 0:
					errors.append("%s.%s: 0以上の整数である必要があります。" % [path, effect_name])
			"goto":
				if typeof(value) != TYPE_STRING:
					errors.append("%s.goto: 文字列である必要があります。" % path)
				else:
					_validate_scene_reference(String(value), "%s.goto" % path, scene_ids, errors)


static func _validate_flag_effect(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: JSONオブジェクトである必要があります。" % path)
		return
	var flags_value: Dictionary = value
	for key_value: Variant in flags_value.keys():
		if typeof(key_value) != TYPE_STRING:
			errors.append("%s: フラグ名は文字列である必要があります。" % path)
			continue
		var flag_name: String = key_value
		if not _is_flag_value(flags_value[flag_name]):
			errors.append("%s.%s: bool、int、string のいずれかである必要があります。" % [path, flag_name])


static func _validate_item_effect(value: Variant, path: String, errors: Array[String]) -> void:
	if typeof(value) == TYPE_STRING:
		if String(value).is_empty():
			errors.append("%s: item_id が空です。" % path)
		return
	if typeof(value) != TYPE_DICTIONARY:
		errors.append("%s: item_id文字列またはJSONオブジェクトである必要があります。" % path)
		return
	var item: Dictionary = value
	_validate_required_string(item, "item_id", "%s.item_id" % path, errors)
	if item.has("count"):
		if not _is_integer_value(item["count"]) or int(item["count"]) <= 0:
			errors.append("%s.count: 1以上の整数である必要があります。" % path)


static func _validate_enemies(enemies_data: Variant, errors: Array[String]) -> Dictionary[String, bool]:
	var enemy_ids: Dictionary[String, bool] = {}
	var entries: Array = []
	if typeof(enemies_data) == TYPE_ARRAY:
		entries = enemies_data
	elif typeof(enemies_data) == TYPE_DICTIONARY:
		var root: Dictionary = enemies_data
		if root.has("enemies") and typeof(root["enemies"]) == TYPE_ARRAY:
			entries = root["enemies"]
		else:
			errors.append("敵データのルート: 配列または enemies 配列を持つ必要があります。")
			return enemy_ids
	else:
		errors.append("敵データのルート: 配列である必要があります。")
		return enemy_ids
	for index: int in range(entries.size()):
		var path: String = "enemies[%d]" % index
		var value: Variant = entries[index]
		if typeof(value) != TYPE_DICTIONARY:
			errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var enemy: Dictionary = value
		if _validate_required_string(enemy, "id", "%s.id" % path, errors):
			var enemy_id: String = enemy["id"]
			if enemy_ids.has(enemy_id):
				errors.append("%s.id: 敵IDが重複しています: %s" % [path, enemy_id])
			else:
				enemy_ids[enemy_id] = true
		_validate_required_string(enemy, "name_ja", "%s.name_ja" % path, errors)
		_validate_integer_range(enemy, "threat", 0, 3, "%s.threat" % path, errors)
		_validate_non_negative_integer(enemy, "hp", "%s.hp" % path, errors)
		_validate_non_negative_integer(enemy, "attack", "%s.attack" % path, errors)
		_validate_string_array(enemy, "traits", "%s.traits" % path, true, errors)
	return enemy_ids


static func _validate_enemy_references(
	value: Variant,
	path: String,
	enemy_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if typeof(value) != TYPE_ARRAY:
		errors.append("%s: 配列である必要があります。" % path)
		return
	var references: Array = value
	for index: int in range(references.size()):
		var enemy_value: Variant = references[index]
		if typeof(enemy_value) != TYPE_STRING:
			errors.append("%s[%d]: 敵IDは文字列である必要があります。" % [path, index])
			continue
		var enemy_id: String = enemy_value
		if not enemy_ids.has(enemy_id):
			errors.append("%s[%d]: enemies.json に存在しない敵IDです: %s" % [path, index, enemy_id])


static func _collect_scene_ids(root: Dictionary, errors: Array[String]) -> Dictionary[String, bool]:
	var scene_ids: Dictionary[String, bool] = {}
	if not root.has("scenes") or typeof(root["scenes"]) != TYPE_ARRAY:
		return scene_ids
	var scenes: Array = root["scenes"]
	for index: int in range(scenes.size()):
		var value: Variant = scenes[index]
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = value
		if not scene.has("id") or typeof(scene["id"]) != TYPE_STRING:
			continue
		var scene_id: String = scene["id"]
		if scene_ids.has(scene_id):
			errors.append("scenes[%d].id: シーンIDが重複しています: %s" % [index, scene_id])
		else:
			scene_ids[scene_id] = true
	return scene_ids


static func _validate_scene_reference(
	scene_id: String,
	path: String,
	scene_ids: Dictionary[String, bool],
	errors: Array[String],
) -> void:
	if not scene_ids.has(scene_id):
		errors.append("%s: 存在しないシーンIDを参照しています: %s" % [path, scene_id])


static func _validate_rewards(root: Dictionary, errors: Array[String]) -> void:
	if not root.has("rewards"):
		errors.append("rewards: 必須項目です。")
		return
	if typeof(root["rewards"]) != TYPE_DICTIONARY:
		errors.append("rewards: JSONオブジェクトである必要があります。")
		return
	var rewards: Dictionary = root["rewards"]
	_validate_non_negative_integer(rewards, "xp", "rewards.xp", errors)
	_validate_non_negative_integer(rewards, "money", "rewards.money", errors)


static func _validate_required_string(
	data_value: Dictionary,
	key: String,
	path: String,
	errors: Array[String],
) -> bool:
	if not data_value.has(key):
		errors.append("%s: 必須項目です。" % path)
		return false
	if typeof(data_value[key]) != TYPE_STRING:
		errors.append("%s: 文字列である必要があります。" % path)
		return false
	if String(data_value[key]).is_empty():
		errors.append("%s: 空文字列は使用できません。" % path)
		return false
	return true


static func _validate_non_negative_integer(
	data_value: Dictionary,
	key: String,
	path: String,
	errors: Array[String],
) -> void:
	if not data_value.has(key):
		errors.append("%s: 必須項目です。" % path)
		return
	if not _is_integer_value(data_value[key]):
		errors.append("%s: 整数である必要があります。" % path)
		return
	if int(data_value[key]) < 0:
		errors.append("%s: 0以上である必要があります。" % path)


static func _validate_integer_range(
	data_value: Dictionary,
	key: String,
	minimum: int,
	maximum: int,
	path: String,
	errors: Array[String],
) -> void:
	if not data_value.has(key) or not _is_integer_value(data_value[key]):
		errors.append("%s: 整数である必要があります。" % path)
		return
	var number: int = int(data_value[key])
	if number < minimum or number > maximum:
		errors.append("%s: %d..%d の範囲外です。" % [path, minimum, maximum])


static func _validate_string_array(
	data_value: Dictionary,
	key: String,
	path: String,
	required: bool,
	errors: Array[String],
) -> void:
	if not data_value.has(key):
		if required:
			errors.append("%s: 必須項目です。" % path)
		return
	if typeof(data_value[key]) != TYPE_ARRAY:
		errors.append("%s: 配列である必要があります。" % path)
		return
	var values: Array = data_value[key]
	for index: int in range(values.size()):
		if typeof(values[index]) != TYPE_STRING:
			errors.append("%s[%d]: 文字列である必要があります。" % [path, index])


static func _apply_set_flags(value: Variant, state: GameState) -> void:
	var new_flags: Dictionary = value
	for key_value: Variant in new_flags.keys():
		var flag_name: String = key_value
		var flag_value: Variant = new_flags[flag_name]
		state.flags[flag_name] = int(flag_value) if _is_integer_value(flag_value) else flag_value


static func _apply_add_item(value: Variant, state: GameState) -> void:
	var item_id: String = _item_id(value)
	var count: int = _item_count(value)
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			item["count"] = int(item.get("count", 0)) + count
			return
	state.character.inventory.append({"item_id": item_id, "count": count})


static func _apply_remove_item(value: Variant, state: GameState) -> void:
	var item_id: String = _item_id(value)
	var count: int = _item_count(value)
	for index: int in range(state.character.inventory.size()):
		var item: Dictionary = state.character.inventory[index]
		if String(item.get("item_id", "")) != item_id:
			continue
		var remaining: int = int(item.get("count", 0)) - count
		if remaining > 0:
			item["count"] = remaining
		else:
			state.character.inventory.remove_at(index)
		return


static func _item_id(value: Variant) -> String:
	if typeof(value) == TYPE_STRING:
		return String(value)
	var item: Dictionary = value
	return String(item["item_id"])


static func _item_count(value: Variant) -> int:
	if typeof(value) == TYPE_STRING:
		return 1
	var item: Dictionary = value
	return int(item.get("count", 1))


static func _read_file(path: String, label: String, errors: Array[String]) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("%sを開けません: %s（%s）" % [label, path, error_string(FileAccess.get_open_error())])
		return null
	return file.get_as_text()


static func _parse_source(source: Variant, label: String, errors: Array[String]) -> Variant:
	if typeof(source) in [TYPE_DICTIONARY, TYPE_ARRAY]:
		return source.duplicate(true)
	if typeof(source) != TYPE_STRING:
		errors.append("%s: JSON文字列、Dictionary、Array のいずれかである必要があります。" % label)
		return null
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(String(source))
	if parse_error != OK:
		errors.append(
			"%sのJSON解析に失敗しました（行%d）: %s"
			% [label, json.get_error_line(), json.get_error_message()]
		)
		return null
	return json.data


static func _is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var float_value: float = value
	return is_finite(float_value) and float_value == floor(float_value)


static func _is_flag_value(value: Variant) -> bool:
	return typeof(value) in [TYPE_BOOL, TYPE_STRING] or _is_integer_value(value)


static func _is_truthy(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT:
			return int(value) != 0
		TYPE_STRING:
			return not String(value).is_empty()
		_:
			return false
