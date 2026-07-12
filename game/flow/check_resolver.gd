class_name CheckResolver


class CheckResolution:
	var success: bool = false
	var reason: String = ""
	var check_id: String = ""
	var branch: String = "効果なし"
	var complication_id: String = ""
	var applied_effects: Array[String] = []
	var no_state_change: bool = false


	func to_dict() -> Dictionary[String, Variant]:
		return {
			"success": success,
			"reason": reason,
			"check_id": check_id,
			"branch": branch,
			"complication_id": complication_id,
			"applied_effects": applied_effects.duplicate(),
			"no_state_change": no_state_change,
		}


static func resolve(
	target: Variant,
	judgment_result: Judgment.Result,
	state: GameState,
	scenario: Scenario,
	rng: RandomNumberGenerator,
) -> CheckResolution:
	var resolution: CheckResolution = CheckResolution.new()
	if target == null:
		resolution.success = true
		resolution.reason = "自由判定のため宣言的効果なしで確定しました。"
		resolution.no_state_change = true
		return resolution
	if typeof(target) != TYPE_STRING or not String(target).begins_with("check:"):
		_fail(resolution, "判定 target が不正なためシナリオ効果を適用できません。")
		return resolution
	resolution.check_id = String(target).trim_prefix("check:")
	if resolution.check_id.is_empty():
		_fail(resolution, "check ID が空のためシナリオ効果を適用できません。")
		return resolution

	var scene: Dictionary = _find_by_field(scenario.data.get("scenes", []), "id", state.scene_id)
	if scene.is_empty():
		_fail(resolution, "現在シーンが見つからないため判定効果を適用できません。")
		return resolution
	var check: Dictionary = _find_by_field(scene.get("checks", []), "id", resolution.check_id)
	if check.is_empty():
		_fail(resolution, "現在シーンに check「%s」がないため効果を適用できません。" % resolution.check_id)
		return resolution

	resolution.branch = _branch_for_tier(judgment_result.tier)
	if resolution.branch.is_empty():
		_fail(resolution, "未知の判定 tier のため分岐を決定できません。")
		return resolution
	if not check.has(resolution.branch):
		resolution.success = true
		resolution.reason = "check「%s」の分岐「%s」は未定義のため効果なしで確定しました。" % [
			resolution.check_id,
			resolution.branch,
		]
		resolution.no_state_change = true
		return resolution

	var branch_effect: Dictionary = check[resolution.branch].duplicate(true)
	var complication_effect: Dictionary = {}
	if resolution.branch == "on_partial":
		var complication: Dictionary = _select_complication(branch_effect, scene, rng)
		if branch_effect.has("complication") and complication.is_empty():
			_fail(
				resolution,
				"check「%s」の指定 complication「%s」が現在シーンにないため効果を適用できません。"
				% [resolution.check_id, String(branch_effect["complication"])],
			)
			return resolution
		branch_effect.erase("complication")
		if not complication.is_empty():
			resolution.complication_id = String(complication.get("id", ""))
			complication_effect = complication.get("effect", {}).duplicate(true)

	var validation_errors: Array[String] = _validate_effects(
		branch_effect,
		complication_effect,
		scenario,
	)
	if not validation_errors.is_empty():
		_fail(
			resolution,
			"check「%s」の分岐「%s」の効果を適用できません: %s"
			% [resolution.check_id, resolution.branch, " / ".join(validation_errors)],
		)
		return resolution

	if not branch_effect.is_empty():
		scenario.apply_effect(branch_effect, state)
		resolution.applied_effects.append("分岐効果: %s" % str(branch_effect))
	if not complication_effect.is_empty():
		scenario.apply_effect(complication_effect, state)
		resolution.applied_effects.append(
			"complication「%s」の効果: %s" % [resolution.complication_id, str(complication_effect)]
		)
	resolution.success = true
	if resolution.applied_effects.is_empty():
		resolution.reason = "check「%s」の分岐「%s」を効果なしで確定しました。" % [
			resolution.check_id,
			resolution.branch,
		]
		resolution.no_state_change = true
	else:
		resolution.reason = "check「%s」の分岐「%s」の宣言的効果を適用しました。" % [
			resolution.check_id,
			resolution.branch,
		]
	return resolution


static func _branch_for_tier(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL, Types.ResultTier.SUCCESS:
			return "on_success"
		Types.ResultTier.PARTIAL:
			return "on_partial"
		Types.ResultTier.FAILURE, Types.ResultTier.FUMBLE:
			return "on_failure"
		_:
			return ""


static func _select_complication(
	branch_effect: Dictionary,
	scene: Dictionary,
	rng: RandomNumberGenerator,
) -> Dictionary:
	var complications_value: Variant = scene.get("complications", [])
	if typeof(complications_value) != TYPE_ARRAY:
		return {}
	var complications: Array = complications_value
	if branch_effect.has("complication"):
		return _find_by_field(complications, "id", String(branch_effect["complication"]))
	if complications.is_empty():
		return {}
	var selected_index: int = rng.randi_range(0, complications.size() - 1)
	var selected_value: Variant = complications[selected_index]
	if typeof(selected_value) != TYPE_DICTIONARY:
		return {}
	var selected: Dictionary = selected_value
	return selected


static func _validate_effects(
	branch_effect: Dictionary,
	complication_effect: Dictionary,
	scenario: Scenario,
) -> Array[String]:
	var errors: Array[String] = []
	var validation_state: GameState = GameState.new()
	if not branch_effect.is_empty():
		errors.append_array(scenario.apply_effect(branch_effect, validation_state))
	if not complication_effect.is_empty():
		errors.append_array(scenario.apply_effect(complication_effect, validation_state))
	return errors


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


static func _fail(resolution: CheckResolution, reason: String) -> void:
	resolution.success = false
	resolution.reason = reason
	resolution.no_state_change = true
