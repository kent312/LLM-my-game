extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"


func test_success_and_critical_apply_on_success() -> void:
	for tier: Types.ResultTier in [Types.ResultTier.SUCCESS, Types.ResultTier.CRITICAL]:
		var state: GameState = _state()
		var resolution: CheckResolver.CheckResolution = _resolve(_fixture(), state, tier)

		assert_true(resolution.success)
		assert_eq(resolution.branch, "on_success")
		assert_eq(resolution.check_id, "check_find_path")
		assert_eq(state.flags["path_found"], true)
		assert_eq(state.scene_id, "depths")


func test_partial_prefers_explicit_complication() -> void:
	var state: GameState = _state()
	state.character.inventory = [{"item_id": "torch", "count": 1}]

	var resolution: CheckResolver.CheckResolution = _resolve(
		_fixture(),
		state,
		Types.ResultTier.PARTIAL,
	)

	assert_true(resolution.success)
	assert_eq(resolution.branch, "on_partial")
	assert_eq(resolution.complication_id, "torch_lost")
	assert_eq(state.clock, 1)
	assert_eq(_item_count(state, "torch"), 0)


func test_partial_without_explicit_id_draws_scene_complication_with_seeded_rng() -> void:
	var data: Dictionary = _fixture().serialize()
	var entrance: Dictionary = _scene(data, "entrance")
	var checks: Array = entrance["checks"]
	var check: Dictionary = checks[0]
	var partial: Dictionary = check["on_partial"]
	partial.erase("complication")
	var complications: Array = entrance["complications"]
	complications.append(
		{
			"id": "noise",
			"effect": {"set_flags": {"alerted": true}},
			"hint_ja": "物音で警戒される",
		}
	)
	var scenario_result: Scenario.LoadResult = Scenario.load(data)
	assert_true(scenario_result.is_success(), str(scenario_result.errors))
	var state: GameState = _state()
	state.character.inventory = [{"item_id": "torch", "count": 1}]
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 2468
	var judgment: Judgment.Result = _judgment(Types.ResultTier.PARTIAL)

	var resolution: CheckResolver.CheckResolution = CheckResolver.resolve(
		"check:check_find_path",
		judgment,
		state,
		scenario_result.scenario,
		rng,
	)

	assert_true(resolution.success)
	assert_true(["torch_lost", "noise"].has(resolution.complication_id))
	if resolution.complication_id == "torch_lost":
		assert_eq(_item_count(state, "torch"), 0)
	else:
		assert_eq(state.flags["alerted"], true)


func test_failure_and_fumble_apply_on_failure() -> void:
	for tier: Types.ResultTier in [Types.ResultTier.FAILURE, Types.ResultTier.FUMBLE]:
		var state: GameState = _state()
		state.character.hp = {"current": 8, "max": 8}
		var resolution: CheckResolver.CheckResolution = _resolve(_fixture(), state, tier)

		assert_true(resolution.success)
		assert_eq(resolution.branch, "on_failure")
		assert_eq(state.character.hp["current"], 7)


func test_undefined_branch_is_confirmed_as_no_effect() -> void:
	var data: Dictionary = _fixture().serialize()
	var entrance: Dictionary = _scene(data, "entrance")
	var checks: Array = entrance["checks"]
	var check: Dictionary = checks[0]
	check.erase("on_failure")
	var scenario_result: Scenario.LoadResult = Scenario.load(data)
	assert_true(scenario_result.is_success(), str(scenario_result.errors))
	var state: GameState = _state()
	var before: Dictionary[String, Variant] = state.serialize()

	var resolution: CheckResolver.CheckResolution = _resolve(
		scenario_result.scenario,
		state,
		Types.ResultTier.FAILURE,
	)

	assert_true(resolution.success)
	assert_true(resolution.no_state_change)
	assert_true(resolution.reason.contains("効果なし"))
	assert_eq(resolution.check_id, "check_find_path")
	assert_eq(resolution.branch, "on_failure")
	assert_eq(state.serialize(), before)


func test_free_check_with_null_target_preserves_state_and_records_no_effect() -> void:
	var state: GameState = _state()
	var before: Dictionary[String, Variant] = state.serialize()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7

	var resolution: CheckResolver.CheckResolution = CheckResolver.resolve(
		null,
		_judgment(Types.ResultTier.SUCCESS),
		state,
		_fixture(),
		rng,
	)

	assert_true(resolution.success)
	assert_true(resolution.no_state_change)
	assert_true(resolution.reason.contains("自由判定"))
	assert_true(resolution.reason.contains("効果なし"))
	assert_eq(resolution.branch, "効果なし")
	assert_eq(state.serialize(), before)


func test_resolution_records_check_id_branch_and_applied_effects() -> void:
	var state: GameState = _state()

	var resolution: CheckResolver.CheckResolution = _resolve(
		_fixture(),
		state,
		Types.ResultTier.SUCCESS,
	)

	assert_eq(resolution.check_id, "check_find_path")
	assert_eq(resolution.branch, "on_success")
	assert_false(resolution.applied_effects.is_empty())
	assert_false(resolution.reason.is_empty())


func _resolve(
	scenario: Scenario,
	state: GameState,
	tier: Types.ResultTier,
) -> CheckResolver.CheckResolution:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 12345
	return CheckResolver.resolve(
		"check:check_find_path",
		_judgment(tier),
		state,
		scenario,
		rng,
	)


func _judgment(tier: Types.ResultTier) -> Judgment.Result:
	var result: Judgment.Result = Judgment.Result.new()
	result.tier = tier
	return result


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "フィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


func _state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	return state


func _scene(data: Dictionary, scene_id: String) -> Dictionary:
	var scenes: Array = data["scenes"]
	for scene_value: Variant in scenes:
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) == scene_id:
			return scene
	return {}


func _item_count(state: GameState, item_id: String) -> int:
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			return int(item.get("count", 0))
	return 0

