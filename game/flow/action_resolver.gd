class_name ActionResolver

const ITEMS_PATH: String = "res://game/data/items.json"


class ActionResolution:
	var success: bool = false
	var reason: String = ""
	var action_type: String = ""
	var target: String = ""
	var applied_effects: Array[String] = []
	var no_state_change: bool = false
	var disclosed_knows: Array[String] = []


	func to_dict() -> Dictionary[String, Variant]:
		return {
			"success": success,
			"reason": reason,
			"action_type": action_type,
			"target": target,
			"applied_effects": applied_effects.duplicate(),
			"no_state_change": no_state_change,
			"disclosed_knows": disclosed_knows.duplicate(),
		}


class ItemsLoadResult:
	var items: Dictionary[String, Dictionary] = {}
	var errors: Array[String] = []


	func is_success() -> bool:
		return errors.is_empty()


static func resolve(
	intent: Dictionary,
	state: GameState,
	scenario: Scenario,
	items_source: Variant = null,
) -> ActionResolution:
	var resolution: ActionResolution = ActionResolution.new()
	resolution.action_type = String(intent.get("action_type", ""))
	var target_value: Variant = intent.get("target", null)
	if typeof(target_value) == TYPE_STRING:
		resolution.target = String(target_value)

	match resolution.action_type:
		"move":
			_resolve_move(resolution, state, scenario)
		"item":
			_resolve_item(resolution, state, scenario, items_source)
		"talk":
			_resolve_talk(resolution, state, scenario)
		"other":
			resolution.success = true
			resolution.reason = "雑談・観察として状態変更なしで確定しました。"
			resolution.no_state_change = true
		_:
			_fail(resolution, "未対応の action_type のため実行不可です。")
	return resolution


static func _resolve_move(
	resolution: ActionResolution,
	state: GameState,
	scenario: Scenario,
) -> void:
	var destination_id: String = _target_id(resolution.target, "exit:")
	if destination_id.is_empty():
		_fail(resolution, "移動先 target が不正なため実行不可です。")
		return
	var scene: Dictionary = _find_current_scene(state, scenario)
	if scene.is_empty():
		_fail(resolution, "現在シーンが見つからないため移動を実行できません。")
		return
	var exit_data: Dictionary = _find_by_field(scene.get("exits", []), "goto", destination_id)
	if exit_data.is_empty():
		_fail(resolution, "現在シーンに指定された出口がないため実行不可です。")
		return
	if exit_data.has("condition"):
		var condition: String = String(exit_data["condition"])
		var condition_result: Scenario.ConditionResult = Scenario.evaluate_condition(condition, state)
		if not condition_result.is_success():
			_fail(
				resolution,
				"出口条件を評価できないため実行不可です: %s" % " / ".join(condition_result.errors),
			)
			return
		if not condition_result.value:
			_fail(resolution, "出口条件「%s」を満たさないため実行不可です。" % condition)
			return

	var effect: Dictionary = {"goto": destination_id}
	if exit_data.has("set_flags"):
		effect["set_flags"] = exit_data["set_flags"]
	var errors: Array[String] = scenario.apply_effect(effect, state)
	if not errors.is_empty():
		_fail(resolution, "移動効果を適用できないため実行不可です: %s" % " / ".join(errors))
		return
	resolution.success = true
	resolution.reason = "出口定義に基づきシーン「%s」へ移動しました。" % destination_id
	resolution.applied_effects.append("シーン移動: %s" % destination_id)
	if exit_data.has("set_flags"):
		resolution.applied_effects.append("出口フラグ設定: %s" % str(exit_data["set_flags"]))


static func _resolve_item(
	resolution: ActionResolution,
	state: GameState,
	scenario: Scenario,
	items_source: Variant,
) -> void:
	var item_id: String = _target_id(resolution.target, "item:")
	if item_id.is_empty():
		_fail(resolution, "アイテム target が不正なため実行不可です。")
		return
	if _inventory_count(state, item_id) <= 0:
		_fail(resolution, "アイテム「%s」を所持していないため実行不可です。" % item_id)
		return
	var load_result: ItemsLoadResult = _load_items(items_source, scenario)
	if not load_result.is_success():
		_fail(resolution, "アイテム定義を読み込めないため実行不可です: %s" % " / ".join(load_result.errors))
		return
	if not load_result.items.has(item_id):
		_fail(resolution, "アイテム「%s」のマスター定義がないため実行不可です。" % item_id)
		return
	var item: Dictionary = load_result.items[item_id]
	if not item.has("effect"):
		_fail(resolution, "アイテム「%s」には使用効果がないため実行不可です。" % item_id)
		return
	var effect: Dictionary = item["effect"]
	var errors: Array[String] = scenario.apply_effect(effect, state)
	if not errors.is_empty():
		_fail(resolution, "アイテム効果を適用できないため実行不可です: %s" % " / ".join(errors))
		return
	_consume_one(state, item_id)
	resolution.success = true
	resolution.reason = "アイテム「%s」の定義済み効果を適用し、1個消費しました。" % item_id
	resolution.applied_effects.append("アイテム効果: %s" % str(effect))
	resolution.applied_effects.append("アイテム消費: %s x1" % item_id)


static func _resolve_talk(
	resolution: ActionResolution,
	state: GameState,
	scenario: Scenario,
) -> void:
	var npc_id: String = _target_id(resolution.target, "npc:")
	if npc_id.is_empty():
		_fail(resolution, "会話相手 target が不正なため実行不可です。")
		return
	var scene: Dictionary = _find_current_scene(state, scenario)
	if scene.is_empty():
		_fail(resolution, "現在シーンが見つからないため会話を実行できません。")
		return
	var npc: Dictionary = _find_by_field(scene.get("npcs", []), "id", npc_id)
	if npc.is_empty():
		_fail(resolution, "NPC「%s」が現在シーンにいないため実行不可です。" % npc_id)
		return
	var knows_value: Variant = npc.get("knows", [])
	if typeof(knows_value) != TYPE_ARRAY:
		_fail(resolution, "NPC「%s」の knows 定義が不正なため実行不可です。" % npc_id)
		return
	var knows_values: Array = knows_value
	for value: Variant in knows_values:
		if typeof(value) != TYPE_STRING:
			_fail(resolution, "NPC「%s」の knows に文字列以外があるため実行不可です。" % npc_id)
			return
	var talked_flag: String = "talked_%s" % npc_id
	state.flags[talked_flag] = true
	for knows_entry: Variant in knows_values:
		resolution.disclosed_knows.append(String(knows_entry))
	resolution.success = true
	resolution.reason = "現在シーンのNPC「%s」との会話を確定しました。" % npc_id
	resolution.applied_effects.append("会話済みフラグ設定: %s=true" % talked_flag)
	if not resolution.disclosed_knows.is_empty():
		resolution.applied_effects.append("NPC knows 開示: %s" % str(resolution.disclosed_knows))


static func _load_items(source: Variant, scenario: Scenario) -> ItemsLoadResult:
	var result: ItemsLoadResult = ItemsLoadResult.new()
	var resolved_source: Variant = source
	if resolved_source == null:
		var file: FileAccess = FileAccess.open(ITEMS_PATH, FileAccess.READ)
		if file == null:
			result.errors.append(
				"アイテムデータを開けません: %s（%s）"
				% [ITEMS_PATH, error_string(FileAccess.get_open_error())]
			)
			return result
		resolved_source = file.get_as_text()
	var parsed: Variant = _parse_items_source(resolved_source, result.errors)
	if not result.errors.is_empty():
		return result
	var entries: Array = []
	if typeof(parsed) == TYPE_ARRAY:
		entries = parsed
	elif typeof(parsed) == TYPE_DICTIONARY:
		var root: Dictionary = parsed
		if root.has("items") and typeof(root["items"]) == TYPE_ARRAY:
			entries = root["items"]
		else:
			result.errors.append("アイテムデータのルートには items 配列が必要です。")
			return result
	else:
		result.errors.append("アイテムデータのルートは配列またはJSONオブジェクトである必要があります。")
		return result

	for index: int in range(entries.size()):
		var path: String = "items[%d]" % index
		var value: Variant = entries[index]
		if typeof(value) != TYPE_DICTIONARY:
			result.errors.append("%s: JSONオブジェクトである必要があります。" % path)
			continue
		var item: Dictionary = value
		if not _has_non_empty_string(item, "id"):
			result.errors.append("%s.id: 空でない文字列が必要です。" % path)
			continue
		var item_id: String = String(item["id"])
		if result.items.has(item_id):
			result.errors.append("%s.id: アイテムIDが重複しています: %s" % [path, item_id])
			continue
		if not _has_non_empty_string(item, "name_ja"):
			result.errors.append("%s.name_ja: 空でない文字列が必要です。" % path)
			continue
		if item.has("effect"):
			if typeof(item["effect"]) != TYPE_DICTIONARY:
				result.errors.append("%s.effect: JSONオブジェクトである必要があります。" % path)
				continue
			var effect: Dictionary = item["effect"]
			var validation_state: GameState = GameState.new()
			var effect_errors: Array[String] = scenario.apply_effect(effect, validation_state)
			for effect_error: String in effect_errors:
				result.errors.append("%s.%s" % [path, effect_error])
		result.items[item_id] = item.duplicate(true)
	return result


static func _parse_items_source(source: Variant, errors: Array[String]) -> Variant:
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


static func _find_current_scene(state: GameState, scenario: Scenario) -> Dictionary:
	return _find_by_field(scenario.data.get("scenes", []), "id", state.scene_id)


static func _find_by_field(values_value: Variant, field: String, expected: String) -> Dictionary:
	if typeof(values_value) != TYPE_ARRAY:
		return {}
	var values: Array = values_value
	for value: Variant in values:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = value
		if String(entry.get(field, "")) == expected:
			return entry
	return {}


static func _target_id(target: String, prefix: String) -> String:
	if not target.begins_with(prefix):
		return ""
	return target.trim_prefix(prefix)


static func _inventory_count(state: GameState, item_id: String) -> int:
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			return int(item.get("count", 0))
	return 0


static func _consume_one(state: GameState, item_id: String) -> void:
	for index: int in range(state.character.inventory.size()):
		var item: Dictionary = state.character.inventory[index]
		if String(item.get("item_id", "")) != item_id:
			continue
		var remaining: int = int(item.get("count", 0)) - 1
		if remaining > 0:
			item["count"] = remaining
		else:
			state.character.inventory.remove_at(index)
		return


static func _has_non_empty_string(data: Dictionary, key: String) -> bool:
	return data.has(key) and typeof(data[key]) == TYPE_STRING and not String(data[key]).is_empty()


static func _fail(resolution: ActionResolution, reason: String) -> void:
	resolution.success = false
	resolution.reason = reason
	resolution.no_state_change = true
