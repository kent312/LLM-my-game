class_name Judgment


class Request:
	var ability: Types.Ability = Types.Ability.STR
	var skill_tags: Array[String] = []
	var situation_mod: int = 0:
		set(value):
			# 意図分類やシナリオデータの境界で、許可範囲へ必ず収める。
			situation_mod = clampi(value, -2, 2)
	var roll_mode: Types.RollMode = Types.RollMode.NORMAL


class Result:
	var dice: Array[int] = []
	var kept: Array[int] = []
	var natural: int = 0
	var ability_mod: int = 0
	var skill_bonus: int = 0
	var applied_tag: String = ""
	var rejected_tags: Array[String] = []
	var situation_mod: int = 0
	var total: int = 0
	var tier: Types.ResultTier = Types.ResultTier.FAILURE


static func resolve(
	req: Request,
	sheet: CharacterSheet,
	rng: RandomNumberGenerator,
) -> Result:
	# 乱数生成と有利・不利の採用処理は Dice に集約する（INV-2）。
	var roll_result: Dictionary[String, Variant] = Dice.roll(req.roll_mode, rng)
	var rolled_dice: Array[int] = roll_result["dice"]
	var rolled_kept: Array[int] = roll_result["kept"]
	var result: Result = Result.new()
	result.dice = rolled_dice.duplicate()
	result.kept = rolled_kept.duplicate()
	result.natural = roll_result["natural"]

	# 自然目の段階を修正適用前に確定し、通常のしきい値判定から保護する。
	var natural_tier_is_fixed: bool = false
	if result.natural == 12:
		result.tier = Types.ResultTier.CRITICAL
		natural_tier_is_fixed = true
	elif result.natural == 2:
		result.tier = Types.ResultTier.FUMBLE
		natural_tier_is_fixed = true

	var ability_key: String = _ability_key(req.ability)
	assert(
		sheet.abilities.has(ability_key),
		"キャラクターシートに能力値がありません: %s" % ability_key,
	)
	result.ability_mod = sheet.abilities[ability_key]
	_apply_skill_bonus(req.skill_tags, sheet, result)
	result.situation_mod = req.situation_mod
	result.total = (
		result.natural
		+ result.ability_mod
		+ result.skill_bonus
		+ result.situation_mod
	)

	# クリティカル／ファンブルでも、上記の全計算根拠と total はログ用に残す。
	if natural_tier_is_fixed:
		return result
	if result.total >= Types.THRESHOLD_SUCCESS:
		result.tier = Types.ResultTier.SUCCESS
	elif result.total >= Types.THRESHOLD_PARTIAL:
		result.tier = Types.ResultTier.PARTIAL
	else:
		result.tier = Types.ResultTier.FAILURE
	return result


static func _apply_skill_bonus(
	requested_tags: Array[String],
	sheet: CharacterSheet,
	result: Result,
) -> void:
	var character_tags: Dictionary[String, bool] = _collect_character_tags(sheet)
	for tag_id: String in requested_tags:
		if result.applied_tag.is_empty() and character_tags.has(tag_id):
			result.applied_tag = tag_id
			result.skill_bonus = Types.SKILL_BONUS
		else:
			# 最初の一致以外は、一致したタグも含めて不採用理由の記録対象にする。
			result.rejected_tags.append(tag_id)


static func _collect_character_tags(sheet: CharacterSheet) -> Dictionary[String, bool]:
	var character_tags: Dictionary[String, bool] = {}
	for tag_id: String in sheet.skills:
		character_tags[tag_id] = true
	for specialty: Dictionary in sheet.specialties:
		var specialty_tags: Array = specialty.get("tags", [])
		for tag_value: Variant in specialty_tags:
			character_tags[String(tag_value)] = true
	return character_tags


static func _ability_key(ability: Types.Ability) -> String:
	# enum の宣言順に依存させず、CharacterSheet の保存キーへ明示的に変換する。
	match ability:
		Types.Ability.STR:
			return "STR"
		Types.Ability.DEX:
			return "DEX"
		Types.Ability.CON:
			return "CON"
		Types.Ability.INT:
			return "INT"
		Types.Ability.WIS:
			return "WIS"
		Types.Ability.CHA:
			return "CHA"
		_:
			assert(false, "不正な Ability 値です: %d" % ability)
			return ""
