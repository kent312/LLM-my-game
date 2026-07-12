extends GutTest

const VALID_CHARACTER_JSON: String = """
{
	"name": "ミナ",
	"description": "古代遺跡を巡る探索者",
	"abilities": {"STR": 0, "DEX": 2, "CON": 1, "INT": 0, "WIS": 1, "CHA": 0},
	"hp": {"current": 10, "max": 10},
	"skills": ["skill.stealth", "skill.perception"],
	"specialties": [
		{"label": "古代史", "tags": ["knowledge.history"]},
		{"label": "鍵開け", "tags": ["craft.lockpicking"]}
	],
	"xp": 0,
	"inventory": [{"item_id": "torch", "count": 2}],
	"money": 30
}
"""


func test_loads_valid_json() -> void:
	var result: CharacterSheet.LoadResult = CharacterSheet.load(VALID_CHARACTER_JSON)

	assert_true(result.is_success(), "正常JSONのロードに失敗しました: %s" % str(result.errors))
	if result.sheet == null:
		return
	assert_eq(result.sheet.name, "ミナ")
	assert_eq(result.sheet.abilities["DEX"], 2)
	assert_eq(result.sheet.hp["current"], 10)
	assert_true(result.sheet.validate().is_empty())


func test_ability_outside_minus_one_to_three_returns_validation_errors() -> void:
	var low_data: Dictionary[String, Variant] = _valid_character_data()
	var low_abilities: Dictionary = low_data["abilities"]
	low_abilities["STR"] = Types.ABILITY_MIN - 1
	var low_result: CharacterSheet.LoadResult = CharacterSheet.load(low_data, _tag_ids())

	var high_data: Dictionary[String, Variant] = _valid_character_data()
	var high_abilities: Dictionary = high_data["abilities"]
	high_abilities["CHA"] = Types.ABILITY_MAX + 1
	var high_result: CharacterSheet.LoadResult = CharacterSheet.load(high_data, _tag_ids())

	assert_true(_contains_error(low_result.errors, "abilities.STR"))
	assert_true(_contains_error(low_result.errors, "-1..3 の範囲外"))
	assert_true(_contains_error(high_result.errors, "abilities.CHA"))
	assert_true(_contains_error(high_result.errors, "-1..3 の範囲外"))


func test_unknown_skill_and_specialty_tags_return_validation_errors() -> void:
	var data: Dictionary[String, Variant] = _valid_character_data()
	var raw_skills: Array = data["skills"]
	raw_skills.append("skill.unknown")
	var raw_specialties: Array = data["specialties"]
	var first_specialty: Dictionary = raw_specialties[0]
	var specialty_tags: Array = first_specialty["tags"]
	specialty_tags.append("knowledge.unknown")

	var result: CharacterSheet.LoadResult = CharacterSheet.load(data, _tag_ids())

	assert_true(_contains_error(result.errors, "skill.unknown"))
	assert_true(_contains_error(result.errors, "knowledge.unknown"))
	assert_true(_contains_error(result.errors, "タクソノミーに存在しないタグID"))


func test_con_one_derives_hp_max_ten() -> void:
	assert_eq(CharacterSheet.derive_max_hp(1), 10)

	var data: Dictionary[String, Variant] = _valid_character_data()
	var raw_hp: Dictionary = data["hp"]
	raw_hp["max"] = 9
	var result: CharacterSheet.LoadResult = CharacterSheet.load(data, _tag_ids())

	assert_true(_contains_error(result.errors, "CONから導出した値 10"))


func test_serialize_then_load_preserves_contents() -> void:
	var first_result: CharacterSheet.LoadResult = CharacterSheet.load(
		VALID_CHARACTER_JSON,
		_tag_ids(),
	)
	assert_true(first_result.is_success(), "初回ロードに失敗しました: %s" % str(first_result.errors))
	if first_result.sheet == null:
		return

	var serialized: Dictionary[String, Variant] = first_result.sheet.serialize()
	var serialized_json: String = JSON.stringify(serialized)
	var second_result: CharacterSheet.LoadResult = CharacterSheet.load(
		serialized_json,
		_tag_ids(),
	)

	assert_true(second_result.is_success(), "再ロードに失敗しました: %s" % str(second_result.errors))
	if second_result.sheet == null:
		return
	assert_eq(second_result.sheet.serialize(), serialized)


func _valid_character_data() -> Dictionary[String, Variant]:
	return {
		"name": "ミナ",
		"description": "古代遺跡を巡る探索者",
		"abilities": {"STR": 0, "DEX": 2, "CON": 1, "INT": 0, "WIS": 1, "CHA": 0},
		"hp": {"current": 10, "max": 10},
		"skills": ["skill.stealth", "skill.perception"],
		"specialties": [
			{"label": "古代史", "tags": ["knowledge.history"]},
			{"label": "鍵開け", "tags": ["craft.lockpicking"]},
		],
		"xp": 0,
		"inventory": [{"item_id": "torch", "count": 2}],
		"money": 30,
	}


func _tag_ids() -> Dictionary[String, bool]:
	return {
		"skill.stealth": true,
		"skill.perception": true,
		"knowledge.history": true,
		"craft.lockpicking": true,
	}


func _contains_error(errors: Array[String], fragment: String) -> bool:
	for error_message: String in errors:
		if error_message.contains(fragment):
			return true
	return false
