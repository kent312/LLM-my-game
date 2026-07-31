class_name UIFormat
extends RefCounted

enum TextKind { NARRATION, NPC_DIALOGUE, SYSTEM, PLAYER }

const HIGHLIGHT_COLOR: String = "#91d7c2"
const NARRATION_COLOR: String = "#c9c2db"
const NPC_COLOR: String = "#9fd2c0"
const SYSTEM_COLOR: String = "#d5b878"
const PLAYER_COLOR: String = "#8fc6b2"
const MUTED_COLOR: String = "#9aa8b8"
const TIER_COLORS: Dictionary = {
	Types.ResultTier.CRITICAL: "#75d69a",
	Types.ResultTier.SUCCESS: "#75d69a",
	Types.ResultTier.PARTIAL: "#e0c36e",
	Types.ResultTier.FAILURE: "#e58b8b",
	Types.ResultTier.FUMBLE: "#e58b8b",
}


static func escape_bbcode(text: String) -> String:
	var escaped: String = ""
	for index: int in range(text.length()):
		var character: String = text.substr(index, 1)
		match character:
			"[":
				escaped += "[lb]"
			"]":
				escaped += "[rb]"
			_:
				escaped += character
	return escaped


static func highlight_known_terms(text: String, known_terms: Array[String]) -> String:
	var terms: Array[String] = _normalized_terms(known_terms)
	var output: String = ""
	var index: int = 0
	while index < text.length():
		var matched_term: String = ""
		for term: String in terms:
			if text.substr(index, term.length()) == term:
				matched_term = term
				break
		if matched_term.is_empty():
			output += escape_bbcode(text.substr(index, 1))
			index += 1
			continue
		output += "[color=%s][b]%s[/b][/color]" % [
			HIGHLIGHT_COLOR,
			escape_bbcode(matched_term),
		]
		index += matched_term.length()
	return output


static func format_log_entry(
	kind: TextKind,
	speaker: String,
	text: String,
	known_terms: Array[String] = [],
) -> String:
	var escaped_speaker: String = escape_bbcode(speaker)
	match kind:
		TextKind.NARRATION:
			return "[color=%s][i]%s[/i][/color]\n%s" % [
				NARRATION_COLOR,
				escaped_speaker,
				_format_story_body(text, known_terms),
			]
		TextKind.NPC_DIALOGUE:
			return "[bgcolor=#202b3c][color=%s][b]%s[/b][/color]\n%s[/bgcolor]" % [
				NPC_COLOR,
				escaped_speaker,
				highlight_known_terms(text, known_terms),
			]
		TextKind.PLAYER:
			return "[color=%s][b]%s[/b][/color]\n%s" % [
				PLAYER_COLOR,
				escaped_speaker,
				escape_bbcode(text),
			]
		_:
			return "[bgcolor=#242b30][color=%s][b]%s[/b][/color]\n[color=#c9c3ad]%s[/color][/bgcolor]" % [
				SYSTEM_COLOR,
				escaped_speaker,
				escape_bbcode(text),
			]


static func format_judgment_card(result: Judgment.Result) -> String:
	var tier_color: String = tier_color(result.tier)
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
		"[bgcolor=#1b242b][color=%s][b]%s · %s[/b][/color]\n"
		+ "[color=%s]%s: %s[/color]\n"
		+ "[font_size=19][b](%s) + %+d + %+d + %+d = %d  vs %d[/b][/font_size]\n"
		+ "[color=%s]%s: %d / %s: %d[/color]\n"
		+ "%s: [color=%s]%s[/color]\n"
		+ "%s: [color=%s]%s[/color][/bgcolor]"
	) % [
		tier_color,
		_translated("判定"),
		_tier_name(result.tier),
		MUTED_COLOR,
		_translated("採用出目"),
		kept_text,
		kept_text,
		result.ability_mod,
		result.skill_bonus,
		result.situation_mod,
		result.total,
		Types.THRESHOLD_SUCCESS,
		MUTED_COLOR,
		_translated("完全成功の閾値"),
		Types.THRESHOLD_SUCCESS,
		_translated("部分成功の閾値"),
		Types.THRESHOLD_PARTIAL,
		_translated("適用タグ"),
		tier_color,
		applied_tag,
		_translated("不採用タグ"),
		MUTED_COLOR,
		rejected_tags,
	]


static func format_status(state: GameState) -> String:
	var character: CharacterSheet = state.character
	var inventory_lines: Array[String] = []
	for entry: Dictionary in character.inventory:
		inventory_lines.append(
			_translated("%s × %d") % [
				String(entry.get("item_id", "")),
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
	return String(TIER_COLORS.get(tier, "#e58b8b"))


static func _format_story_body(text: String, known_terms: Array[String]) -> String:
	var formatted_lines: Array[String] = []
	for line: String in text.split("\n"):
		var formatted_line: String = highlight_known_terms(line, known_terms)
		if _looks_like_npc_dialogue(line):
			formatted_line = "[color=%s][i]%s[/i][/color]" % [
				NPC_COLOR,
				formatted_line,
			]
		else:
			formatted_line = "[color=#e2ddd0]%s[/color]" % formatted_line
		formatted_lines.append(formatted_line)
	return "\n".join(formatted_lines)


static func _looks_like_npc_dialogue(line: String) -> bool:
	var stripped: String = line.strip_edges()
	return (
		stripped.begins_with("「")
		or stripped.contains("：「")
		or stripped.contains(": 「")
		or (stripped.contains("「") and stripped.contains("」"))
	)


static func _normalized_terms(known_terms: Array[String]) -> Array[String]:
	var unique_terms: Array[String] = []
	for term: String in known_terms:
		if not term.is_empty() and not unique_terms.has(term):
			unique_terms.append(term)
	for left: int in range(unique_terms.size()):
		for right: int in range(left + 1, unique_terms.size()):
			if unique_terms[right].length() > unique_terms[left].length():
				var longer_term: String = unique_terms[right]
				unique_terms[right] = unique_terms[left]
				unique_terms[left] = longer_term
	return unique_terms


static func _tier_name(tier: Types.ResultTier) -> String:
	match tier:
		Types.ResultTier.CRITICAL:
			return _translated("CRITICAL")
		Types.ResultTier.SUCCESS:
			return _translated("SUCCESS")
		Types.ResultTier.PARTIAL:
			return _translated("PARTIAL")
		Types.ResultTier.FAILURE:
			return _translated("FAILURE")
		Types.ResultTier.FUMBLE:
			return _translated("FUMBLE")
		_:
			return _translated("UNKNOWN")


static func _translated(message: String) -> String:
	var formatter: UIFormat = UIFormat.new()
	return formatter.tr(message)
