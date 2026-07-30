extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"


func test_damage_and_effect_are_validated_by_one_registry() -> void:
	var source: Dictionary = {
		"items": [
			{"id": "blade", "name_ja": "試験剣", "damage": 2},
			{"id": "medicine", "name_ja": "試験薬", "effect": {"heal": 2}},
		],
	}

	var result: ItemRegistry.LoadResult = ItemRegistry.load(_fixture(), source)

	assert_true(result.is_success(), str(result.errors))
	assert_eq(result.items["blade"]["damage"], 2)
	assert_eq(result.items["medicine"]["effect"], {"heal": 2})


func test_invalid_damage_and_effect_are_both_rejected() -> void:
	var source: Dictionary = {
		"items": [
			{
				"id": "broken",
				"name_ja": "壊れた試験品",
				"damage": 0,
				"effect": {"run_script": "bad"},
			},
		],
	}

	var result: ItemRegistry.LoadResult = ItemRegistry.load(_fixture(), source)

	assert_false(result.is_success())
	assert_true(_contains_error(result.errors, "damage: 1以上"))
	assert_true(_contains_error(result.errors, "未知の effect 名"))
	assert_false(result.items.has("broken"))


func test_default_registry_returns_defensive_copies_from_cache() -> void:
	var scenario: Scenario = _fixture()
	var first: ItemRegistry.LoadResult = ItemRegistry.load(scenario)
	assert_true(first.is_success(), str(first.errors))
	assert_true(first.items.has("shortbow"))
	var first_shortbow: Dictionary = first.items["shortbow"]
	first_shortbow["damage"] = 999

	var second: ItemRegistry.LoadResult = ItemRegistry.load(scenario)

	assert_true(second.is_success(), str(second.errors))
	assert_true(second.items.has("shortbow"))
	assert_ne(int(second.items["shortbow"]["damage"]), 999)


func test_data_lookup_finds_dictionary_by_exact_field() -> void:
	var values: Array[Dictionary] = [
		{"id": "first", "value": 1},
		{"id": "second", "value": 2},
	]

	assert_eq(DataLookup.find_by_field(values, "id", "second")["value"], 2)
	assert_true(DataLookup.find_by_field(values, "id", "missing").is_empty())
	assert_true(DataLookup.find_by_field("not_array", "id", "first").is_empty())


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "フィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


func _contains_error(errors: Array[String], fragment: String) -> bool:
	for error_message: String in errors:
		if error_message.contains(fragment):
			return true
	return false
