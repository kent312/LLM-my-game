extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"


func test_fixture_loads_and_validates() -> void:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)

	assert_true(result.is_success(), "フィクスチャのロードに失敗しました: %s" % str(result.errors))
	if result.scenario == null:
		return
	assert_eq(result.scenario.data["id"], "test_fixture")
	assert_eq(result.scenario.data["scenes"].size(), 3)


func test_all_seven_effect_words_are_applied() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.character.inventory = [{"item_id": "torch", "count": 2}]
	state.character.hp = {"current": 6, "max": 8}

	assert_true(scenario.apply_effect({"set_flags": {"door_open": true}}, state).is_empty())
	assert_true(scenario.apply_effect({"add_item": {"item_id": "potion", "count": 2}}, state).is_empty())
	assert_true(scenario.apply_effect({"remove_item": "torch"}, state).is_empty())
	assert_true(scenario.apply_effect({"damage": 3}, state).is_empty())
	assert_true(scenario.apply_effect({"heal": 2}, state).is_empty())
	assert_true(scenario.apply_effect({"advance_clock": 2}, state).is_empty())
	assert_true(scenario.apply_effect({"goto": "depths"}, state).is_empty())

	assert_eq(state.flags["door_open"], true)
	assert_eq(_item_count(state, "potion"), 2)
	assert_eq(_item_count(state, "torch"), 1)
	assert_eq(state.character.hp["current"], 5)
	assert_eq(state.clock, 2)
	assert_eq(state.scene_id, "depths")


func test_unknown_effect_returns_error_without_applying_known_effect() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()

	var errors: Array[String] = scenario.apply_effect(
		{"set_flags": {"must_not_change": true}, "run_script": "bad"},
		state,
	)

	assert_true(_contains_error(errors, "未知の effect 名"))
	assert_false(state.flags.has("must_not_change"), "検証失敗時に一部の effect を適用してはいけません。")


func test_goto_references_in_exits_and_effects_must_exist() -> void:
	var exit_data: Dictionary = _fixture_data()
	var exit_scenes: Array = exit_data["scenes"]
	var first_exit_scene: Dictionary = exit_scenes[0]
	var exits: Array = first_exit_scene["exits"]
	var first_exit: Dictionary = exits[0]
	first_exit["goto"] = "missing_scene"
	var exit_result: Scenario.LoadResult = Scenario.load(exit_data)

	var effect_data: Dictionary = _fixture_data()
	var effect_scenes: Array = effect_data["scenes"]
	var first_effect_scene: Dictionary = effect_scenes[0]
	var checks: Array = first_effect_scene["checks"]
	var first_check: Dictionary = checks[0]
	var success_effect: Dictionary = first_check["on_success"]
	success_effect["goto"] = "missing_scene"
	var effect_result: Scenario.LoadResult = Scenario.load(effect_data)

	assert_true(_contains_error(exit_result.errors, "存在しないシーンID"))
	assert_true(_contains_error(exit_result.errors, "exits[0].goto"))
	assert_true(_contains_error(effect_result.errors, "存在しないシーンID"))
	assert_true(_contains_error(effect_result.errors, "on_success.goto"))


func test_damage_never_reduces_hp_below_zero() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.character.hp = {"current": 2, "max": 8}

	var errors: Array[String] = scenario.apply_effect({"damage": 99}, state)

	assert_true(errors.is_empty())
	assert_eq(state.character.hp["current"], 0)


func test_heal_never_increases_hp_above_max() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.character.hp = {"current": 7, "max": 8}

	var errors: Array[String] = scenario.apply_effect({"heal": 99}, state)

	assert_true(errors.is_empty())
	assert_eq(state.character.hp["current"], 8)


func test_check_id_is_required_and_unique_within_scene() -> void:
	var missing_data: Dictionary = _fixture_data()
	var missing_scenes: Array = missing_data["scenes"]
	var missing_scene: Dictionary = missing_scenes[0]
	var missing_checks: Array = missing_scene["checks"]
	var missing_check: Dictionary = missing_checks[0]
	missing_check.erase("id")
	var missing_result: Scenario.LoadResult = Scenario.load(missing_data)

	var duplicate_data: Dictionary = _fixture_data()
	var duplicate_scenes: Array = duplicate_data["scenes"]
	var duplicate_scene: Dictionary = duplicate_scenes[0]
	var duplicate_checks: Array = duplicate_scene["checks"]
	duplicate_checks.append(duplicate_checks[0].duplicate(true))
	var duplicate_result: Scenario.LoadResult = Scenario.load(duplicate_data)

	assert_true(_contains_error(missing_result.errors, "checks[0].id: 必須項目"))
	assert_true(_contains_error(duplicate_result.errors, "check ID が重複"))


func test_on_defeat_is_required() -> void:
	var data: Dictionary = _fixture_data()
	data.erase("on_defeat")

	var result: Scenario.LoadResult = Scenario.load(data)

	assert_true(_contains_error(result.errors, "on_defeat: 必須項目"))


func test_scene_enemy_and_enemies_ref_must_exist_in_enemy_master() -> void:
	var scene_data: Dictionary = _fixture_data()
	var scenes: Array = scene_data["scenes"]
	var first_scene: Dictionary = scenes[0]
	var scene_enemies: Array = first_scene["enemies"]
	scene_enemies.append("unknown_scene_enemy")
	var scene_result: Scenario.LoadResult = Scenario.load(scene_data)

	var ref_data: Dictionary = _fixture_data()
	var enemy_refs: Array = ref_data["enemies_ref"]
	enemy_refs.append("unknown_ref_enemy")
	var ref_result: Scenario.LoadResult = Scenario.load(ref_data)

	assert_true(_contains_error(scene_result.errors, "unknown_scene_enemy"))
	assert_true(_contains_error(scene_result.errors, "enemies.json に存在しない敵ID"))
	assert_true(_contains_error(ref_result.errors, "unknown_ref_enemy"))
	assert_true(_contains_error(ref_result.errors, "enemies.json に存在しない敵ID"))


func test_flag_and_clock_conditions_are_evaluated() -> void:
	var state: GameState = _state()
	state.flags["door_open"] = true
	state.flags["empty"] = ""
	state.clock = 3

	var true_flag: Scenario.ConditionResult = Scenario.evaluate_condition("flag:door_open", state)
	var false_flag: Scenario.ConditionResult = Scenario.evaluate_condition("flag:empty", state)
	var reached_clock: Scenario.ConditionResult = Scenario.evaluate_condition("clock:3", state)
	var future_clock: Scenario.ConditionResult = Scenario.evaluate_condition("clock:4", state)

	assert_true(true_flag.is_success())
	assert_true(true_flag.value)
	assert_false(false_flag.value)
	assert_true(reached_clock.value, "clock:<n> は n 以上で成立する必要があります。")
	assert_false(future_clock.value)


func test_unknown_condition_syntax_is_validation_error() -> void:
	var state: GameState = _state()
	var evaluation: Scenario.ConditionResult = Scenario.evaluate_condition("item:torch", state)

	var data: Dictionary = _fixture_data()
	var scenes: Array = data["scenes"]
	var first_scene: Dictionary = scenes[0]
	var exits: Array = first_scene["exits"]
	var first_exit: Dictionary = exits[0]
	first_exit["condition"] = "script:anything"
	var load_result: Scenario.LoadResult = Scenario.load(data)

	assert_false(evaluation.is_success())
	assert_true(_contains_error(evaluation.errors, "未知の condition 構文"))
	assert_true(_contains_error(load_result.errors, "未知の condition 構文"))


func test_rewards_add_xp_and_money_to_character() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.character.xp = 4
	state.character.money = 10

	var errors: Array[String] = scenario.grant_rewards(state)

	assert_true(errors.is_empty())
	assert_eq(state.character.xp, 7)
	assert_eq(state.character.money, 60)


func test_game_state_serialize_and_deserialize_round_trip() -> void:
	var state: GameState = _state()
	state.flags = {"opened": true, "count": 2, "note": "済"}
	state.active_enemies = [
		{"enemy_id": "goblin", "hp": {"current": 3, "max": 4}},
	]
	state.clock = 2
	state.turn_count = 5
	state.pending_narration = {"kind": "check", "tier": "partial"}
	var serialized: Dictionary[String, Variant] = state.serialize()

	var result: GameState.LoadResult = GameState.deserialize(JSON.stringify(serialized))

	assert_true(result.is_success(), "GameState の復元に失敗しました: %s" % str(result.errors))
	if result.state == null:
		return
	assert_eq(result.state.serialize(), serialized)


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "テスト前提のフィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


func _fixture_data() -> Dictionary:
	return _fixture().serialize()


func _state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	return state


func _item_count(state: GameState, item_id: String) -> int:
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			return int(item.get("count", 0))
	return 0


func _contains_error(errors: Array[String], fragment: String) -> bool:
	for error_message: String in errors:
		if error_message.contains(fragment):
			return true
	return false
