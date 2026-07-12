extends GutTest

# Godot 4.7 の RandomNumberGenerator（PCG32）について、seed を 0 から順に設定し、
# target.size() 回の randi_range(1, 6) が目的列と一致する最初の seed を探索した。
# 探索結果: [4,3]=13、[6,6]=23、[1,1]=3、[5,2,6]=100、[1,5,1]=15。
const SEED_DICE_4_3: int = 13
const SEED_DICE_6_6: int = 23
const SEED_DICE_1_1: int = 3
const SEED_DICE_5_2_6: int = 100
const SEED_DICE_1_5_1: int = 15


func test_partial_success_vector() -> void:
	var sheet: CharacterSheet = _sheet_with_ability("DEX", 2)
	var request: Judgment.Request = _request(
		Types.Ability.DEX,
		["skill.stealth"],
		0,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_4_3))

	assert_eq(result.dice, [4, 3])
	assert_eq(result.kept, [4, 3])
	assert_eq(result.natural, 7)
	assert_eq(result.ability_mod, 2)
	assert_eq(result.skill_bonus, 0)
	assert_eq(result.applied_tag, "")
	assert_eq(result.rejected_tags, ["skill.stealth"])
	assert_eq(result.situation_mod, 0)
	assert_eq(result.total, 9)
	assert_eq(result.tier, Types.ResultTier.PARTIAL)


func test_success_vector() -> void:
	var sheet: CharacterSheet = _sheet_with_ability("DEX", 2)
	sheet.skills = ["skill.stealth"]
	var request: Judgment.Request = _request(
		Types.Ability.DEX,
		["skill.stealth"],
		0,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_4_3))

	assert_eq(result.dice, [4, 3])
	assert_eq(result.natural, 7)
	assert_eq(result.ability_mod, 2)
	assert_eq(result.skill_bonus, 1)
	assert_eq(result.applied_tag, "skill.stealth")
	assert_eq(result.rejected_tags, [])
	assert_eq(result.total, 10)
	assert_eq(result.tier, Types.ResultTier.SUCCESS)


func test_critical_takes_priority_vector() -> void:
	var sheet: CharacterSheet = _sheet_with_ability("STR", -1)
	var request: Judgment.Request = _request(Types.Ability.STR, [], -2)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_6_6))

	assert_eq(result.dice, [6, 6])
	assert_eq(result.natural, 12)
	assert_eq(result.ability_mod, -1)
	assert_eq(result.situation_mod, -2)
	assert_eq(result.total, 9)
	assert_eq(result.tier, Types.ResultTier.CRITICAL)


func test_fumble_takes_priority_vector() -> void:
	var sheet: CharacterSheet = _sheet_with_ability("CHA", 3)
	sheet.skills = ["skill.persuasion"]
	var request: Judgment.Request = _request(
		Types.Ability.CHA,
		["skill.persuasion"],
		2,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_1_1))

	assert_eq(result.dice, [1, 1])
	assert_eq(result.natural, 2)
	assert_eq(result.ability_mod, 3)
	assert_eq(result.skill_bonus, 1)
	assert_eq(result.applied_tag, "skill.persuasion")
	assert_eq(result.situation_mod, 2)
	assert_eq(result.total, 8)
	assert_eq(result.tier, Types.ResultTier.FUMBLE)


func test_advantage_vector() -> void:
	var sheet: CharacterSheet = CharacterSheet.new()
	var request: Judgment.Request = _request(
		Types.Ability.STR,
		[],
		0,
		Types.RollMode.ADVANTAGE,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_5_2_6))

	assert_eq(result.dice, [5, 2, 6])
	assert_eq(result.kept, [6, 5])
	assert_eq(result.natural, 11)


func test_disadvantage_fumble_vector() -> void:
	var sheet: CharacterSheet = CharacterSheet.new()
	var request: Judgment.Request = _request(
		Types.Ability.STR,
		[],
		0,
		Types.RollMode.DISADVANTAGE,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_1_5_1))

	assert_eq(result.dice, [1, 5, 1])
	assert_eq(result.kept, [1, 1])
	assert_eq(result.natural, 2)
	assert_eq(result.tier, Types.ResultTier.FUMBLE)


func test_multiple_matching_tags_do_not_stack_vector() -> void:
	var sheet: CharacterSheet = CharacterSheet.new()
	sheet.skills = ["skill.stealth"]
	sheet.specialties = [
		{"label": "軽業", "tags": ["body.acrobatics"]},
	]
	var request: Judgment.Request = _request(
		Types.Ability.DEX,
		["skill.stealth", "body.acrobatics"],
		0,
	)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_4_3))

	assert_eq(result.skill_bonus, 1)
	assert_eq(result.applied_tag, "skill.stealth")
	assert_eq(result.rejected_tags, ["body.acrobatics"])


func test_situation_modifier_is_clamped_vector() -> void:
	var sheet: CharacterSheet = CharacterSheet.new()
	var request: Judgment.Request = _request(Types.Ability.STR, [], 5)

	assert_eq(request.situation_mod, 2)

	var result: Judgment.Result = Judgment.resolve(request, sheet, _rng(SEED_DICE_4_3))

	assert_eq(result.situation_mod, 2)
	assert_eq(result.total, 9)


func _sheet_with_ability(ability_key: String, ability_mod: int) -> CharacterSheet:
	var sheet: CharacterSheet = CharacterSheet.new()
	sheet.abilities[ability_key] = ability_mod
	return sheet


func _request(
	ability: Types.Ability,
	skill_tags: Array[String],
	situation_mod: int,
	roll_mode: Types.RollMode = Types.RollMode.NORMAL,
) -> Judgment.Request:
	var request: Judgment.Request = Judgment.Request.new()
	request.ability = ability
	request.skill_tags = skill_tags.duplicate()
	request.situation_mod = situation_mod
	request.roll_mode = roll_mode
	return request


func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng
