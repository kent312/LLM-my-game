class_name Combat

const UNARMED_ID: String = "unarmed"
const UNARMED_NAME_JA: String = "素手"
const UNARMED_DAMAGE: int = 1
const ATTACK_ABILITIES: Array[String] = ["STR", "DEX"]


class Resolution:
	var success: bool = false
	var reason: String = ""
	var enemy_id: String = ""
	var enemy_name_ja: String = ""
	var branch: String = ""
	var weapon_id: String = ""
	var weapon_name_ja: String = ""
	var weapon_damage: int = 0
	var damage_dealt: int = 0
	var damage_taken: int = 0
	var enemy_attack: int = 0
	var complication_id: String = ""
	var complication_hint_ja: String = ""
	var applied_effects: Array[String] = []
	var enemy_defeated: bool = false
	var incapacitated: bool = false
	var no_state_change: bool = false


	func to_dict() -> Dictionary[String, Variant]:
		return {
			"success": success,
			"reason": reason,
			"enemy_id": enemy_id,
			"enemy_name_ja": enemy_name_ja,
			"branch": branch,
			"weapon_id": weapon_id,
			"weapon_name_ja": weapon_name_ja,
			"weapon_damage": weapon_damage,
			"damage_dealt": damage_dealt,
			"damage_taken": damage_taken,
			"enemy_attack": enemy_attack,
			"complication_id": complication_id,
			"complication_hint_ja": complication_hint_ja,
			"applied_effects": applied_effects.duplicate(),
			"enemy_defeated": enemy_defeated,
			"incapacitated": incapacitated,
			"no_state_change": no_state_change,
		}


static func resolve(
	intent: Dictionary,
	judgment_result: Judgment.Result,
	state: GameState,
	scenario: Scenario,
	rng: RandomNumberGenerator,
	items_source: Variant = null,
) -> Resolution:
	var resolution: Resolution = Resolution.new()
	if String(intent.get("action_type", "")) != "attack":
		_fail(resolution, "attack 以外の意図は戦闘解決できません。")
		return resolution
	var ability: String = String(intent.get("ability", ""))
	if not ATTACK_ABILITIES.has(ability):
		_fail(resolution, "攻撃の ability は STR または DEX である必要があります。")
		return resolution
	var target_value: Variant = intent.get("target", null)
	if typeof(target_value) != TYPE_STRING or not String(target_value).begins_with("enemy:"):
		_fail(resolution, "攻撃 target が不正です。")
		return resolution
	resolution.enemy_id = String(target_value).trim_prefix("enemy:")
	if resolution.enemy_id.is_empty():
		_fail(resolution, "攻撃対象の敵IDが空です。")
		return resolution

	var enemy_index: int = _find_active_enemy_index(state, resolution.enemy_id)
	if enemy_index < 0:
		_fail(resolution, "攻撃対象が active_enemies に存在しません。")
		return resolution
	var enemy_definition: Dictionary = scenario.enemy_definition(resolution.enemy_id)
	if enemy_definition.is_empty():
		_fail(resolution, "攻撃対象の敵マスター定義がありません。")
		return resolution
	resolution.enemy_name_ja = String(enemy_definition["name_ja"])
	resolution.enemy_attack = int(enemy_definition["attack"])

	var items_result: ItemRegistry.LoadResult = ItemRegistry.load(scenario, items_source)
	if not items_result.is_success():
		_fail(
			resolution,
			"武器データを読み込めません: %s" % " / ".join(items_result.errors),
		)
		return resolution
	var weapon: Dictionary = _select_weapon(state, items_result.items)
	resolution.weapon_id = String(weapon["id"])
	resolution.weapon_name_ja = String(weapon["name_ja"])
	resolution.weapon_damage = int(weapon["damage"])
	resolution.branch = _branch_for_tier(judgment_result.tier)
	if resolution.branch.is_empty():
		_fail(resolution, "未知の判定 tier のため攻撃分岐を決定できません。")
		return resolution

	var complication: Dictionary = {}
	if resolution.branch == "PARTIAL":
		complication = _select_complication(state, scenario, rng)
		if not complication.is_empty():
			resolution.complication_id = String(complication.get("id", ""))
			resolution.complication_hint_ja = String(complication.get("hint_ja", ""))
			var complication_effect: Dictionary = complication.get("effect", {})
			var validation_errors: Array[String] = scenario.apply_effect(
				complication_effect,
				GameState.new(),
			)
			if not validation_errors.is_empty():
				_fail(
					resolution,
					"代償効果を適用できません: %s" % " / ".join(validation_errors),
				)
				return resolution

	var incapacitated_before: bool = bool(state.flags.get("incapacitated", false))
	match resolution.branch:
		"CRITICAL":
			resolution.damage_dealt = resolution.weapon_damage * 2
			_apply_enemy_damage(
				state,
				enemy_index,
				resolution.damage_dealt,
				resolution,
				scenario,
			)
		"SUCCESS":
			resolution.damage_dealt = resolution.weapon_damage
			_apply_enemy_damage(
				state,
				enemy_index,
				resolution.damage_dealt,
				resolution,
				scenario,
			)
		"PARTIAL":
			resolution.damage_dealt = resolution.weapon_damage
			_apply_enemy_damage(
				state,
				enemy_index,
				resolution.damage_dealt,
				resolution,
				scenario,
			)
			if not complication.is_empty():
				var complication_effect: Dictionary = complication["effect"]
				var complication_errors: Array[String] = scenario.apply_effect(
					complication_effect,
					state,
				)
				assert(complication_errors.is_empty(), "検証済みの代償効果を適用できません。")
				resolution.applied_effects.append(
					"代償「%s」: %s" % [
						resolution.complication_id,
						str(complication_effect),
					]
				)
		"FAILURE":
			resolution.damage_taken = resolution.enemy_attack
			var damage_errors: Array[String] = scenario.apply_effect(
				{"damage": resolution.damage_taken},
				state,
			)
			assert(damage_errors.is_empty(), "敵攻撃ダメージを適用できません。")
			resolution.applied_effects.append(
				"PCダメージ: %d" % resolution.damage_taken
			)
		_:
			assert(false, "戦闘分岐に未実装の値があります: %s" % resolution.branch)

	if (
		not incapacitated_before
		and bool(state.flags.get("incapacitated", false))
	):
		resolution.incapacitated = true
		resolution.applied_effects.append("行動不能: incapacitated=true")
		resolution.applied_effects.append(
			"on_defeat: %s" % str(scenario.data.get("on_defeat", {}))
		)
	resolution.success = true
	resolution.reason = _resolution_reason(resolution)
	return resolution


static func _apply_enemy_damage(
	state: GameState,
	enemy_index: int,
	damage: int,
	resolution: Resolution,
	scenario: Scenario,
) -> void:
	var enemy: Dictionary = state.active_enemies[enemy_index]
	var hp: Dictionary = enemy["hp"]
	hp["current"] = maxi(0, int(hp["current"]) - damage)
	resolution.applied_effects.append(
		"敵「%s」へ%dダメージ" % [resolution.enemy_name_ja, damage]
	)
	if int(hp["current"]) > 0:
		return
	state.active_enemies.remove_at(enemy_index)
	var defeated_flag: String = "defeated_%s" % resolution.enemy_id
	var flag_errors: Array[String] = scenario.apply_effect(
		{"set_flags": {defeated_flag: true}},
		state,
	)
	assert(flag_errors.is_empty(), "敵撃破フラグを適用できません。")
	resolution.enemy_defeated = true
	resolution.applied_effects.append(
		"敵「%s」を撃破（%s=true）" % [
			resolution.enemy_name_ja,
			defeated_flag,
		]
	)


static func _select_weapon(
	state: GameState,
	items: Dictionary[String, Dictionary],
) -> Dictionary:
	var selected: Dictionary = {
		"id": UNARMED_ID,
		"name_ja": UNARMED_NAME_JA,
		"damage": UNARMED_DAMAGE,
	}
	var weapon_found: bool = false
	for inventory_entry: Dictionary in state.character.inventory:
		if int(inventory_entry.get("count", 0)) <= 0:
			continue
		var item_id: String = String(inventory_entry.get("item_id", ""))
		if not items.has(item_id):
			continue
		var item: Dictionary = items[item_id]
		if not item.has("damage"):
			continue
		if not weapon_found or int(item["damage"]) > int(selected["damage"]):
			selected = {
				"id": item_id,
				"name_ja": String(item["name_ja"]),
				"damage": int(item["damage"]),
			}
			weapon_found = true
	return selected


static func _select_complication(
	state: GameState,
	scenario: Scenario,
	rng: RandomNumberGenerator,
) -> Dictionary:
	var scene: Dictionary = DataLookup.find_by_field(
		scenario.data.get("scenes", []),
		"id",
		state.scene_id,
	)
	var complications_value: Variant = scene.get("complications", [])
	if typeof(complications_value) != TYPE_ARRAY:
		return {}
	var complications: Array = complications_value
	if complications.is_empty():
		return {}
	var selected_value: Variant = complications[rng.randi_range(0, complications.size() - 1)]
	if typeof(selected_value) != TYPE_DICTIONARY:
		return {}
	var selected: Dictionary = selected_value
	return selected


static func _branch_for_tier(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL:
			return "CRITICAL"
		Types.ResultTier.SUCCESS:
			return "SUCCESS"
		Types.ResultTier.PARTIAL:
			return "PARTIAL"
		Types.ResultTier.FAILURE, Types.ResultTier.FUMBLE:
			return "FAILURE"
		_:
			return ""


static func _resolution_reason(resolution: Resolution) -> String:
	if resolution.branch == "FAILURE":
		return "攻撃失敗として敵攻撃力%dのPC被弾を確定しました。" % resolution.damage_taken
	if resolution.branch == "PARTIAL":
		if resolution.complication_id.is_empty():
			return "部分成功として武器ダメージを確定しました（代償候補なし）。"
		return "部分成功として武器ダメージと代償「%s」を確定しました。" % resolution.complication_id
	return "%sとして武器ダメージ%dを確定しました。" % [
		resolution.branch,
		resolution.damage_dealt,
	]


static func _find_active_enemy_index(state: GameState, enemy_id: String) -> int:
	for index: int in range(state.active_enemies.size()):
		var enemy: Dictionary = state.active_enemies[index]
		if String(enemy.get("enemy_id", "")) == enemy_id:
			return index
	return -1


static func _fail(resolution: Resolution, reason: String) -> void:
	resolution.success = false
	resolution.reason = reason
	resolution.no_state_change = true
