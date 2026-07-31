class_name UIFormat
extends RefCounted

enum TextKind { NARRATION, NPC_DIALOGUE, SYSTEM, PLAYER }

const HIGHLIGHT_COLOR: String = "#91d7c2"
const NARRATION_COLOR: String = "#c9c2db"
const NARRATION_TEXT_COLOR: String = "#e2ddd0"
const NPC_COLOR: String = "#9fd2c0"
const NPC_BACKGROUND_COLOR: String = "#202b3c"
const SYSTEM_COLOR: String = "#d5b878"
const SYSTEM_TEXT_COLOR: String = "#c9c3ad"
const SYSTEM_BACKGROUND_COLOR: String = "#242b30"
const PLAYER_COLOR: String = "#8fc6b2"
const MUTED_COLOR: String = "#9aa8b8"
const CARD_BACKGROUND_COLOR: String = "#1b242b"
const SUCCESS_TIER_COLOR: String = "#75d69a"
const PARTIAL_TIER_COLOR: String = "#e0c36e"
const FAILURE_TIER_COLOR: String = "#e58b8b"
const BRACKET_LEFT_PLACEHOLDER: String = "\u001e"
const BRACKET_RIGHT_PLACEHOLDER: String = "\u001f"
const TIER_COLORS: Dictionary[int, String] = {
	Types.ResultTier.CRITICAL: SUCCESS_TIER_COLOR,
	Types.ResultTier.SUCCESS: SUCCESS_TIER_COLOR,
	Types.ResultTier.PARTIAL: PARTIAL_TIER_COLOR,
	Types.ResultTier.FAILURE: FAILURE_TIER_COLOR,
	Types.ResultTier.FUMBLE: FAILURE_TIER_COLOR,
}


static func escape_bbcode(text: String) -> String:
	# 置換で生成する [lb] / [rb] 自体を後続置換で壊さないよう、一度プレースホルダへ退避する。
	return (
		text.replace("[", BRACKET_LEFT_PLACEHOLDER)
		.replace("]", BRACKET_RIGHT_PLACEHOLDER)
		.replace(BRACKET_LEFT_PLACEHOLDER, "[lb]")
		.replace(BRACKET_RIGHT_PLACEHOLDER, "[rb]")
	)


static func normalize_known_terms(known_terms: Array[String]) -> Array[String]:
	var unique_terms: Array[String] = []
	for term: String in known_terms:
		if not term.is_empty() and not unique_terms.has(term):
			unique_terms.append(term)
	unique_terms.sort_custom(_term_is_longer)
	return unique_terms


static func highlight_known_terms(text: String, normalized_terms: Array[String]) -> String:
	var output: String = ""
	var cursor: int = 0
	while cursor < text.length():
		var match_position: int = -1
		var matched_term: String = ""
		for term: String in normalized_terms:
			var candidate_position: int = text.find(term, cursor)
			if candidate_position < 0:
				continue
			if match_position < 0 or candidate_position < match_position:
				match_position = candidate_position
				matched_term = term
		if match_position < 0:
			output += escape_bbcode(text.substr(cursor))
			break
		if match_position > cursor:
			output += escape_bbcode(text.substr(cursor, match_position - cursor))
		output += "[color=%s][b]%s[/b][/color]" % [
			HIGHLIGHT_COLOR,
			escape_bbcode(matched_term),
		]
		cursor = match_position + matched_term.length()
	return output


static func format_log_entry(
	kind: TextKind,
	speaker: String,
	text: String,
	normalized_terms: Array[String] = [],
) -> String:
	var escaped_speaker: String = escape_bbcode(speaker)
	match kind:
		TextKind.NARRATION:
			return "[color=%s][i]%s[/i][/color]\n%s" % [
				NARRATION_COLOR,
				escaped_speaker,
				_format_story_body(text, normalized_terms),
			]
		TextKind.NPC_DIALOGUE:
			return "[bgcolor=%s][color=%s][b]%s[/b][/color]\n%s[/bgcolor]" % [
				NPC_BACKGROUND_COLOR,
				NPC_COLOR,
				escaped_speaker,
				highlight_known_terms(text, normalized_terms),
			]
		TextKind.PLAYER:
			return "[color=%s][b]%s[/b][/color]\n%s" % [
				PLAYER_COLOR,
				escaped_speaker,
				escape_bbcode(text),
			]
		_:
			return "[bgcolor=%s][color=%s][b]%s[/b][/color]\n[color=%s]%s[/color][/bgcolor]" % [
				SYSTEM_BACKGROUND_COLOR,
				SYSTEM_COLOR,
				escaped_speaker,
				SYSTEM_TEXT_COLOR,
				escape_bbcode(text),
			]


static func format_judgment_card(result: Judgment.Result) -> String:
	var result_color: String = tier_color(result.tier)
	var kept_values: Array[String] = []
	for die: int in result.kept:
		kept_values.append(str(die))
	var kept_text: String = " + ".join(kept_values)
	var applied_tag: String = _translated("なし")
	if not result.applied_tag.is_empty():
		applied_tag = _translated("%s（完全一致、%+d）") % [
			escape_bbcode(result.applied_tag),
			result.skill_bonus,
		]
	var rejected_tags: String = _translated("なし")
	if not result.rejected_tags.is_empty():
		var escaped_tags: Array[String] = []
		for tag: String in result.rejected_tags:
			escaped_tags.append(escape_bbcode(tag))
		rejected_tags = _translated("%s（完全一致なし、またはボーナス重複）") % (
			", ".join(escaped_tags)
		)
	return (
		"[bgcolor=%s][color=%s][b]%s · %s[/b][/color]\n"
		+ "[color=%s]%s: %s / %s: %d[/color]\n"
		+ "[font_size=19][b](%s) + %s %+d + %s %+d + %s %+d = %s %d[/b][/font_size]\n"
		+ "[color=%s]%s[/color]\n"
		+ "[color=%s]%s: %d / %s: %d[/color]\n"
		+ "%s: [color=%s]%s[/color]\n"
		+ "%s: [color=%s]%s[/color][/bgcolor]"
	) % [
		CARD_BACKGROUND_COLOR,
		result_color,
		_translated("判定"),
		tier_label(result.tier),
		MUTED_COLOR,
		_translated("採用出目"),
		kept_text,
		_translated("自然目"),
		result.natural,
		kept_text,
		_translated("能力値"),
		result.ability_mod,
		_translated("スキル"),
		result.skill_bonus,
		_translated("状況"),
		result.situation_mod,
		_translated("合計"),
		result.total,
		result_color,
		_judgment_basis(result),
		MUTED_COLOR,
		_translated("完全成功の閾値"),
		Types.THRESHOLD_SUCCESS,
		_translated("部分成功の閾値"),
		Types.THRESHOLD_PARTIAL,
		_translated("適用タグ"),
		result_color,
		applied_tag,
		_translated("不採用タグ"),
		MUTED_COLOR,
		rejected_tags,
	]


static func format_status(
	state: GameState,
	item_names: Dictionary[String, String] = {},
) -> String:
	var character: CharacterSheet = state.character
	var inventory_lines: Array[String] = []
	for entry: Dictionary in character.inventory:
		var item_id: String = String(entry.get("item_id", ""))
		var display_name: String = item_names.get(item_id, item_id)
		inventory_lines.append(
			_translated("%s × %d") % [
				display_name,
				int(entry.get("count", 0)),
			]
		)
	if inventory_lines.is_empty():
		inventory_lines.append(_translated("なし"))
	return (
		_translated("%s\nHP %d / %d\nXP %d　所持金 %d\n\n能力値\n筋力 %+d　敏捷 %+d　体力 %+d\n知力 %+d　判断 %+d　魅力 %+d\n\n所持品\n%s")
		% [
			character.name,
			int(character.hp.get("current", 0)),
			int(character.hp.get("max", 0)),
			character.xp,
			character.money,
			int(character.abilities.get("STR", 0)),
			int(character.abilities.get("DEX", 0)),
			int(character.abilities.get("CON", 0)),
			int(character.abilities.get("INT", 0)),
			int(character.abilities.get("WIS", 0)),
			int(character.abilities.get("CHA", 0)),
			"\n".join(inventory_lines),
		]
	)


static func tier_color(tier: Types.ResultTier) -> String:
	return TIER_COLORS.get(tier, FAILURE_TIER_COLOR)


static func tier_label(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.FUMBLE:
			return _translated("ファンブル")
		Types.ResultTier.FAILURE:
			return _translated("失敗")
		Types.ResultTier.PARTIAL:
			return _translated("部分成功")
		Types.ResultTier.SUCCESS:
			return _translated("成功")
		Types.ResultTier.CRITICAL:
			return _translated("クリティカル")
		_:
			return _translated("不明")


static func _judgment_basis(result: Judgment.Result) -> String:
	if result.natural == 12:
		return _translated("自然目12のため自動クリティカル（合計%dは参考値）") % result.total
	if result.natural == 2:
		return _translated("自然目2のため自動ファンブル（合計%dは参考値）") % result.total
	match result.tier:
		Types.ResultTier.SUCCESS:
			return _translated("合計%dは完全成功の閾値%d以上") % [
				result.total,
				Types.THRESHOLD_SUCCESS,
			]
		Types.ResultTier.PARTIAL:
			return _translated("合計%dは部分成功の範囲%d〜%d") % [
				result.total,
				Types.THRESHOLD_PARTIAL,
				Types.THRESHOLD_SUCCESS - 1,
			]
		_:
			return _translated("合計%dは部分成功の閾値%d未満") % [
				result.total,
				Types.THRESHOLD_PARTIAL,
			]


static func _format_story_body(text: String, normalized_terms: Array[String]) -> String:
	var formatted_lines: Array[String] = []
	for line: String in text.split("\n"):
		var formatted_line: String = highlight_known_terms(line, normalized_terms)
		if _looks_like_npc_dialogue(line):
			formatted_line = "[color=%s][i]%s[/i][/color]" % [
				NPC_COLOR,
				formatted_line,
			]
		else:
			formatted_line = "[color=%s]%s[/color]" % [
				NARRATION_TEXT_COLOR,
				formatted_line,
			]
		formatted_lines.append(formatted_line)
	return "\n".join(formatted_lines)


static func _looks_like_npc_dialogue(line: String) -> bool:
	return line.strip_edges().begins_with("「")


static func _term_is_longer(left: String, right: String) -> bool:
	if left.length() == right.length():
		return left < right
	return left.length() > right.length()


static func _translated(message: String) -> String:
	# Object.tr() と同じ TranslationServer を通し、純関数呼び出しごとのインスタンス生成を避ける。
	return String(TranslationServer.translate(message))
