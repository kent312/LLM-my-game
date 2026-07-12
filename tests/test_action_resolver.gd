extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"


func test_move_updates_scene_when_exit_condition_is_met() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.flags["path_found"] = true

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "move", "target": "exit:depths", "summary_ja": "無視される自由文"},
		state,
		scenario,
	)

	assert_true(resolution.success)
	assert_eq(state.scene_id, "depths")
	assert_false(resolution.applied_effects.is_empty())


func test_move_condition_failure_is_unavailable_and_preserves_state() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	var before: Dictionary[String, Variant] = state.serialize()

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "move", "target": "exit:depths"},
		state,
		scenario,
	)

	assert_false(resolution.success)
	assert_true(resolution.reason.contains("実行不可"))
	assert_eq(state.serialize(), before)


func test_owned_item_applies_master_effect_and_consumes_one() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	state.character.hp = {"current": 3, "max": 8}
	state.character.inventory = [{"item_id": "potion", "count": 2}]

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "item", "target": "item:potion"},
		state,
		scenario,
	)

	assert_true(resolution.success)
	assert_eq(state.character.hp["current"], 6)
	assert_eq(_item_count(state, "potion"), 1)
	assert_eq(resolution.applied_effects.size(), 2)


func test_unowned_item_is_unavailable_and_preserves_state() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	var before: Dictionary[String, Variant] = state.serialize()

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "item", "target": "item:potion"},
		state,
		scenario,
	)

	assert_false(resolution.success)
	assert_true(resolution.reason.contains("所持していない"))
	assert_eq(state.serialize(), before)


func test_talk_sets_flag_and_records_npc_knows() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "talk", "target": "npc:guide"},
		state,
		scenario,
	)

	assert_true(resolution.success)
	assert_eq(state.flags["talked_guide"], true)
	assert_eq(resolution.disclosed_knows, ["flag:map_hint", "check:check_find_path"])


func test_other_explicitly_records_no_state_change() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _state()
	var before: Dictionary[String, Variant] = state.serialize()

	var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
		{"action_type": "other", "target": null, "summary_ja": "壁を眺める"},
		state,
		scenario,
	)

	assert_true(resolution.success)
	assert_true(resolution.no_state_change)
	assert_eq(state.serialize(), before)


func test_every_action_resolution_has_success_and_japanese_reason() -> void:
	var scenario: Scenario = _fixture()
	var cases: Array[Dictionary] = [
		{"action_type": "move", "target": "exit:missing"},
		{"action_type": "item", "target": "item:missing"},
		{"action_type": "talk", "target": "npc:missing"},
		{"action_type": "other", "target": null},
	]

	for intent: Dictionary in cases:
		var resolution: ActionResolver.ActionResolution = ActionResolver.resolve(
			intent,
			_state(),
			scenario,
		)
		assert_not_null(resolution.success)
		assert_false(resolution.reason.is_empty(), "全ケースに確定理由が必要です。")
		assert_true(
			resolution.reason.contains("。") or resolution.reason.contains("です"),
			"理由は日本語の記録文字列にします。",
		)


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "フィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


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
