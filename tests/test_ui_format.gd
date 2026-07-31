class_name TestUiFormat
extends GutTest

const SEED_DICE_4_3: int = 13
const SEED_DICE_6_6: int = 23
const SEED_DICE_1_1: int = 3
const SEED_DICE_5_2_6: int = 100
const SEED_DICE_1_5_1: int = 15


func test_01_judgment_cards_match_literal_spec_vectors_and_explain_natural_tiers() -> void:
	var results: Array[Judgment.Result] = _judgment_vectors()
	var expected: Array[Dictionary] = [
		{
			"natural": 7,
			"total": 9,
			"tier": Types.ResultTier.PARTIAL,
			"label": "部分成功",
			"basis": "合計9は部分成功の範囲7〜9",
		},
		{
			"natural": 7,
			"total": 10,
			"tier": Types.ResultTier.SUCCESS,
			"label": "成功",
			"basis": "合計10は完全成功の閾値10以上",
		},
		{
			"natural": 12,
			"total": 9,
			"tier": Types.ResultTier.CRITICAL,
			"label": "クリティカル",
			"basis": "自然目12のため自動クリティカル（合計9は参考値）",
		},
		{
			"natural": 2,
			"total": 8,
			"tier": Types.ResultTier.FUMBLE,
			"label": "ファンブル",
			"basis": "自然目2のため自動ファンブル（合計8は参考値）",
		},
		{
			"natural": 11,
			"total": 11,
			"tier": Types.ResultTier.SUCCESS,
			"label": "成功",
			"basis": "合計11は完全成功の閾値10以上",
		},
		{
			"natural": 2,
			"total": 2,
			"tier": Types.ResultTier.FUMBLE,
			"label": "ファンブル",
			"basis": "自然目2のため自動ファンブル（合計2は参考値）",
		},
		{
			"natural": 7,
			"total": 8,
			"tier": Types.ResultTier.PARTIAL,
			"label": "部分成功",
			"basis": "合計8は部分成功の範囲7〜9",
		},
		{
			"natural": 7,
			"total": 9,
			"tier": Types.ResultTier.PARTIAL,
			"label": "部分成功",
			"basis": "合計9は部分成功の範囲7〜9",
		},
	]

	assert_eq(results.size(), 8)
	for index: int in range(expected.size()):
		var result: Judgment.Result = results[index]
		var vector: Dictionary = expected[index]
		assert_eq(result.natural, int(vector["natural"]), "ベクタ%d natural" % index)
		assert_eq(result.total, int(vector["total"]), "ベクタ%d total" % index)
		assert_eq(result.tier, int(vector["tier"]), "ベクタ%d tier" % index)
		var card: String = UIFormat.format_judgment_card(result)
		assert_true(card.contains("自然目: %d" % int(vector["natural"])), card)
		assert_true(card.contains("合計 %d" % int(vector["total"])), card)
		assert_true(card.contains(String(vector["label"])), card)
		assert_true(card.contains(String(vector["basis"])), card)
		assert_true(card.contains("状況 %+d" % result.situation_mod), card)
		assert_false(card.contains("CRITICAL"), card)
		assert_false(card.contains("SUCCESS"), card)
		assert_false(card.contains("PARTIAL"), card)
		assert_false(card.contains("FAILURE"), card)
		assert_false(card.contains("FUMBLE"), card)
		var expected_color: String = _expected_tier_color(int(vector["tier"]))
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
	var terms: Array[String] = UIFormat.normalize_known_terms(
		["鐘守セナ", "銀の月鍵", "霧門"]
	)
	var highlighted: String = UIFormat.highlight_known_terms(source, terms)

	for known_term: String in ["鐘守セナ", "銀の月鍵", "霧門"]:
		assert_true(
			highlighted.contains(
				"[color=%s][b]%s[/b][/color]" % [UIFormat.HIGHLIGHT_COLOR, known_term]
			),
			highlighted,
		)
	assert_true(highlighted.contains("旅人"), highlighted)
	assert_false(highlighted.contains("[b]旅人[/b]"), highlighted)


func test_04_body_brackets_are_escaped_without_breaking_escape_tags() -> void:
	var source: String = "[color=red]偽装[/color] と [b]注入[/b]"
	var escaped: String = UIFormat.escape_bbcode(source)

	assert_eq(UIFormat.escape_bbcode("[x]"), "[lb]x[rb]")
	assert_true(escaped.contains("[lb]color=red[rb]"), escaped)
	assert_true(escaped.contains("[lb]/color[rb]"), escaped)
	assert_true(escaped.contains("[lb]b[rb]"), escaped)
	assert_false(escaped.contains("[color=red]"), escaped)
	assert_false(escaped.contains("[lb[rb]"), escaped)


func test_05_status_uses_game_state_values_and_item_display_names() -> void:
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
		{"item_id": "unknown_relic", "count": 2},
	]
	state.rolling_summary = "AI主張: HP 999、所持金 999、未知の王冠を所持"
	state.recent_logs = ["AI主張: XP 999"]
	var item_names: Dictionary[String, String] = {"moon_key": "銀の月鍵"}

	var status: String = UIFormat.format_status(state, item_names)

	assert_true(status.contains("構造化ユノ"), status)
	assert_true(status.contains("HP 7 / 10"), status)
	assert_true(status.contains("XP 4"), status)
	assert_true(status.contains("所持金 35"), status)
	assert_true(status.contains("銀の月鍵 × 1"), status)
	assert_false(status.contains("moon_key"), status)
	assert_true(status.contains("unknown_relic × 2"), status)
	assert_false(status.contains("999"), status)
	assert_false(status.contains("未知の王冠"), status)


func test_06_log_entry_styles_escape_speakers_and_do_not_misclassify_inline_quotes() -> void:
	var terms: Array[String] = UIFormat.normalize_known_terms(["月鍵"])
	var narration: String = UIFormat.format_log_entry(
		UIFormat.TextKind.NARRATION,
		"[GM]",
		"地の文に「月鍵」が出る。[危険]",
		terms,
	)
	var quoted_dialogue: String = UIFormat.format_log_entry(
		UIFormat.TextKind.NARRATION,
		"GM",
		"「月鍵を渡そう」",
		terms,
	)
	var npc: String = UIFormat.format_log_entry(
		UIFormat.TextKind.NPC_DIALOGUE,
		"[鐘守セナ]",
		"月鍵を探して",
		terms,
	)
	var player: String = UIFormat.format_log_entry(
		UIFormat.TextKind.PLAYER,
		"[あなた]",
		"[調べる]",
		terms,
	)
	var system: String = UIFormat.format_log_entry(
		UIFormat.TextKind.SYSTEM,
		"[システム]",
		"[保存完了]",
		terms,
	)

	assert_true(narration.contains("[lb]GM[rb]"), narration)
	assert_true(narration.contains("[lb]危険[rb]"), narration)
	assert_true(narration.contains("[color=%s]" % UIFormat.NARRATION_TEXT_COLOR), narration)
	assert_false(narration.contains("[color=%s][i]" % UIFormat.NPC_COLOR), narration)
	assert_true(quoted_dialogue.contains("[color=%s][i]" % UIFormat.NPC_COLOR), quoted_dialogue)
	assert_true(npc.contains("[bgcolor=%s]" % UIFormat.NPC_BACKGROUND_COLOR), npc)
	assert_true(npc.contains("[lb]鐘守セナ[rb]"), npc)
	assert_true(player.contains("[color=%s]" % UIFormat.PLAYER_COLOR), player)
	assert_true(player.contains("[lb]調べる[rb]"), player)
	assert_true(system.contains("[bgcolor=%s]" % UIFormat.SYSTEM_BACKGROUND_COLOR), system)
	assert_true(system.contains("[lb]システム[rb]"), system)
	assert_true(system.contains("[lb]保存完了[rb]"), system)


func test_07_highlight_prefers_longest_overlapping_known_term() -> void:
	var terms: Array[String] = UIFormat.normalize_known_terms(
		["霧門", "霧門前広場", "霧門"]
	)
	var highlighted: String = UIFormat.highlight_known_terms(
		"霧門前広場から霧門へ戻る",
		terms,
	)

	assert_eq(terms, ["霧門前広場", "霧門"])
	assert_true(
		highlighted.contains(
			"[color=%s][b]霧門前広場[/b][/color]" % UIFormat.HIGHLIGHT_COLOR
		),
		highlighted,
	)
	assert_true(
		highlighted.contains("[color=%s][b]霧門[/b][/color]へ戻る" % UIFormat.HIGHLIGHT_COLOR),
		highlighted,
	)
	assert_false(highlighted.contains("[b]霧門[/b][/color]前広場"), highlighted)


func test_08_failure_card_explains_total_below_partial_threshold() -> void:
	var result: Judgment.Result = Judgment.Result.new()
	result.kept = [3, 3]
	result.natural = 6
	result.total = 6
	result.tier = Types.ResultTier.FAILURE

	var card: String = UIFormat.format_judgment_card(result)

	assert_true(card.contains("判定 · 失敗"), card)
	assert_true(card.contains("自然目: 6"), card)
	assert_true(card.contains("合計6は部分成功の閾値7未満"), card)


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


func _expected_tier_color(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL, Types.ResultTier.SUCCESS:
			return "#75d69a"
		Types.ResultTier.PARTIAL:
			return "#e0c36e"
		_:
			return "#e58b8b"
