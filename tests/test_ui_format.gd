class_name TestUiFormat
extends GutTest

const SEED_DICE_4_3: int = 13
const SEED_DICE_6_6: int = 23
const SEED_DICE_1_1: int = 3
const SEED_DICE_5_2_6: int = 100
const SEED_DICE_1_5_1: int = 15


func test_01_judgment_cards_contain_every_vector_calculation_threshold_and_tier_color() -> void:
	for result: Judgment.Result in _judgment_vectors():
		var card: String = UIFormat.format_judgment_card(result)
		var kept_values: Array[String] = []
		for die: int in result.kept:
			kept_values.append(str(die))
		var expected_calculation: String = "(%s) + %+d + %+d + %+d = %d" % [
			" + ".join(kept_values),
			result.ability_mod,
			result.skill_bonus,
			result.situation_mod,
			result.total,
		]
		assert_true(card.contains(expected_calculation), card)
		assert_true(card.contains("vs %d" % Types.THRESHOLD_SUCCESS), card)
		assert_true(card.contains("完全成功の閾値: %d" % Types.THRESHOLD_SUCCESS), card)
		assert_true(card.contains("部分成功の閾値: %d" % Types.THRESHOLD_PARTIAL), card)
		assert_true(card.contains(_tier_name(result.tier)), card)
		var expected_color: String = _expected_tier_color(result.tier)
		assert_eq(UIFormat.tier_color(result.tier), expected_color)
		assert_true(card.contains("[color=%s]" % expected_color), card)


func test_02_judgment_card_shows_applied_and_rejected_tags() -> void:
	var result: Judgment.Result = Judgment.Result.new()
	result.kept = [4, 3]
	result.natural = 7
	result.ability_mod = 2
	result.skill_bonus = 1
	result.applied_tag = "skill.stealth"
	result.rejected_tags = ["body.acrobatics", "craft.lockpicking"]
	result.total = 10
	result.tier = Types.ResultTier.SUCCESS

	var card: String = UIFormat.format_judgment_card(result)

	assert_true(card.contains("適用タグ"), card)
	assert_true(card.contains("skill.stealth"), card)
	assert_true(card.contains("不採用タグ"), card)
	assert_true(card.contains("body.acrobatics"), card)
	assert_true(card.contains("craft.lockpicking"), card)
	assert_true(card.contains("完全一致なし、またはボーナス重複"), card)


func test_03_highlight_wraps_only_known_vocabulary() -> void:
	var source: String = "霧門で鐘守セナは銀の月鍵を旅人へ渡した。"
	var highlighted: String = UIFormat.highlight_known_terms(
		source,
		["鐘守セナ", "銀の月鍵", "霧門"],
	)

	for known_term: String in ["鐘守セナ", "銀の月鍵", "霧門"]:
		assert_true(
			highlighted.contains(
				"[color=%s][b]%s[/b][/color]" % [UIFormat.HIGHLIGHT_COLOR, known_term]
			),
			highlighted,
		)
	assert_true(highlighted.contains("旅人"), highlighted)
	assert_false(highlighted.contains("[b]旅人[/b]"), highlighted)


func test_04_body_brackets_are_escaped_before_bbcode_rendering() -> void:
	var source: String = "[color=red]偽装[/color] と [b]注入[/b]"
	var escaped: String = UIFormat.highlight_known_terms(source, [])

	assert_true(escaped.contains("[lb]color=red[rb]"), escaped)
	assert_true(escaped.contains("[lb]/color[rb]"), escaped)
	assert_true(escaped.contains("[lb]b[rb]"), escaped)
	assert_false(escaped.contains("[color=red]"), escaped)
	assert_false(escaped.contains("[b]注入[/b]"), escaped)


func test_05_status_formatter_uses_only_structured_game_state_values() -> void:
	var state: GameState = GameState.new()
	state.character.name = "構造化ユノ"
	state.character.hp = {"current": 7, "max": 10}
	state.character.xp = 4
	state.character.money = 35
	state.character.abilities = {
		"STR": -1,
		"DEX": 1,
		"CON": 1,
		"INT": 1,
		"WIS": 2,
		"CHA": 1,
	}
	state.character.inventory = [
		{"item_id": "moon_key", "count": 1},
		{"item_id": "potion", "count": 2},
	]
	state.rolling_summary = "AI主張: HP 999、所持金 999、未知の王冠を所持"
	state.recent_logs = ["AI主張: XP 999"]

	var status: String = UIFormat.format_status(state)

	assert_true(status.contains("構造化ユノ"), status)
	assert_true(status.contains("HP 7 / 10"), status)
	assert_true(status.contains("XP 4"), status)
	assert_true(status.contains("所持金 35"), status)
	assert_true(status.contains("moon_key × 1"), status)
	assert_true(status.contains("potion × 2"), status)
	assert_false(status.contains("999"), status)
	assert_false(status.contains("未知の王冠"), status)


func _judgment_vectors() -> Array[Judgment.Result]:
	var results: Array[Judgment.Result] = []
	var partial_sheet: CharacterSheet = _sheet_with_ability("DEX", 2)
	results.append(
		Judgment.resolve(
			_request(Types.Ability.DEX, ["skill.stealth"], 0),
			partial_sheet,
			_rng(SEED_DICE_4_3),
		)
	)
	var success_sheet: CharacterSheet = _sheet_with_ability("DEX", 2)
	success_sheet.skills = ["skill.stealth"]
	results.append(
		Judgment.resolve(
			_request(Types.Ability.DEX, ["skill.stealth"], 0),
			success_sheet,
			_rng(SEED_DICE_4_3),
		)
	)
	results.append(
		Judgment.resolve(
			_request(Types.Ability.STR, [], -2),
			_sheet_with_ability("STR", -1),
			_rng(SEED_DICE_6_6),
		)
	)
	var fumble_sheet: CharacterSheet = _sheet_with_ability("CHA", 3)
	fumble_sheet.skills = ["skill.persuasion"]
	results.append(
		Judgment.resolve(
			_request(Types.Ability.CHA, ["skill.persuasion"], 2),
			fumble_sheet,
			_rng(SEED_DICE_1_1),
		)
	)
	results.append(
		Judgment.resolve(
			_request(Types.Ability.STR, [], 0, Types.RollMode.ADVANTAGE),
			CharacterSheet.new(),
			_rng(SEED_DICE_5_2_6),
		)
	)
	results.append(
		Judgment.resolve(
			_request(Types.Ability.STR, [], 0, Types.RollMode.DISADVANTAGE),
			CharacterSheet.new(),
			_rng(SEED_DICE_1_5_1),
		)
	)
	var multi_tag_sheet: CharacterSheet = CharacterSheet.new()
	multi_tag_sheet.skills = ["skill.stealth"]
	multi_tag_sheet.specialties = [{"label": "軽業", "tags": ["body.acrobatics"]}]
	results.append(
		Judgment.resolve(
			_request(
				Types.Ability.DEX,
				["skill.stealth", "body.acrobatics"],
				0,
			),
			multi_tag_sheet,
			_rng(SEED_DICE_4_3),
		)
	)
	results.append(
		Judgment.resolve(
			_request(Types.Ability.STR, [], 5),
			CharacterSheet.new(),
			_rng(SEED_DICE_4_3),
		)
	)
	return results


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


func _tier_name(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL:
			return "CRITICAL"
		Types.ResultTier.SUCCESS:
			return "SUCCESS"
		Types.ResultTier.PARTIAL:
			return "PARTIAL"
		Types.ResultTier.FAILURE:
			return "FAILURE"
		Types.ResultTier.FUMBLE:
			return "FUMBLE"
		_:
			return "UNKNOWN"


func _expected_tier_color(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL, Types.ResultTier.SUCCESS:
			return "#75d69a"
		Types.ResultTier.PARTIAL:
			return "#e0c36e"
		_:
			return "#e58b8b"
