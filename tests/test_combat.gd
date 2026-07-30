extends GutTest

const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"
const TEMP_ROOT: String = "user://test_combat"
const SLOT: int = 16
const SEED_CRITICAL: int = 23
const ITEMS_FIXTURE: Dictionary = {
	"items": [
		{"id": "torch", "name_ja": "試験用松明"},
		{"id": "potion", "name_ja": "試験用薬", "effect": {"heal": 2}},
		{"id": "shortbow", "name_ja": "試験用短弓", "damage": 2},
		{"id": "short_sword", "name_ja": "試験用短剣", "damage": 3},
	],
}


class RecordingBackend:
	extends BackendMock

	var generate_count: int = 0


	func generate(prompt: String, opts: LLMBackend.GenOpts) -> void:
		generate_count += 1
		super.generate(prompt, opts)


class RecordingSaveManager:
	extends SaveManager

	var flush_completed: bool = false
	var saved_snapshots: Array[Dictionary] = []


	func save(slot: int, state_data: Dictionary) -> SaveManager.SaveResult:
		flush_completed = false
		var result: SaveManager.SaveResult = super.save(slot, state_data)
		if result.is_success():
			saved_snapshots.append(state_data.duplicate(true))
			flush_completed = true
		return result


func before_each() -> void:
	_cleanup()


func after_each() -> void:
	_cleanup()


func test_01_critical_deals_twice_weapon_damage() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.inventory = [{"item_id": "short_sword", "count": 1}]

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.CRITICAL,
	)

	assert_true(resolution.success)
	assert_eq(resolution.branch, "CRITICAL")
	assert_eq(resolution.weapon_damage, 3)
	assert_eq(resolution.damage_dealt, 6)
	assert_true(resolution.enemy_defeated)


func test_02_success_deals_weapon_damage() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.inventory = [{"item_id": "short_sword", "count": 1}]

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_true(resolution.success)
	assert_eq(resolution.branch, "SUCCESS")
	assert_eq(resolution.damage_dealt, 3)
	assert_eq(_enemy_hp(state, "goblin"), 1)


func test_03_partial_deals_damage_and_draws_scene_complication() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.inventory = [
		{"item_id": "shortbow", "count": 1},
		{"item_id": "torch", "count": 1},
	]

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.PARTIAL,
	)

	assert_true(resolution.success)
	assert_eq(resolution.branch, "PARTIAL")
	assert_eq(resolution.damage_dealt, 2)
	assert_eq(_enemy_hp(state, "goblin"), 2)
	assert_true(["torch_lost", "noise"].has(resolution.complication_id))
	if resolution.complication_id == "torch_lost":
		assert_eq(_item_count(state, "torch"), 0)
	else:
		assert_eq(state.flags.get("alerted"), true)
	assert_true(_contains_text(resolution.applied_effects, "代償"))


func test_03b_different_seeds_draw_different_complications() -> void:
	var scenario: Scenario = _fixture()
	var first_state: GameState = _combat_state(scenario)
	first_state.character.inventory = [
		{"item_id": "shortbow", "count": 1},
		{"item_id": "torch", "count": 1},
	]
	var second_state: GameState = _combat_state(scenario)
	second_state.character.inventory = first_state.character.inventory.duplicate(true)

	var first: Combat.Resolution = _resolve_with_seed(
		first_state,
		scenario,
		Types.ResultTier.PARTIAL,
		3,
	)
	var second: Combat.Resolution = _resolve_with_seed(
		second_state,
		scenario,
		Types.ResultTier.PARTIAL,
		23,
	)

	assert_true(["torch_lost", "noise"].has(first.complication_id))
	assert_true(["torch_lost", "noise"].has(second.complication_id))
	assert_ne(first.complication_id, second.complication_id)


func test_03c_partial_without_complications_deals_damage_only() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	assert_true(scenario.enter_scene("depths", state).is_empty())
	state.character.inventory = [{"item_id": "shortbow", "count": 1}]

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.PARTIAL,
	)

	assert_true(resolution.success)
	assert_eq(resolution.damage_dealt, 2)
	assert_eq(_enemy_hp(state, "goblin"), 2)
	assert_eq(resolution.complication_id, "")
	assert_false(_contains_text(resolution.applied_effects, "代償"))


func test_04_failure_and_fumble_take_enemy_attack_damage() -> void:
	for tier: Types.ResultTier in [Types.ResultTier.FAILURE, Types.ResultTier.FUMBLE]:
		var scenario: Scenario = _fixture()
		var state: GameState = _combat_state(scenario)

		var resolution: Combat.Resolution = _resolve(state, scenario, tier)

		assert_true(resolution.success)
		assert_eq(resolution.branch, "FAILURE")
		assert_eq(resolution.enemy_attack, 2)
		assert_eq(resolution.damage_taken, 2)
		assert_eq(state.character.hp["current"], 6)
		assert_eq(_enemy_hp(state, "goblin"), 4)


func test_05_selects_highest_owned_weapon_or_unarmed_and_records_it() -> void:
	var scenario: Scenario = _fixture()
	var armed_state: GameState = _combat_state(scenario)
	armed_state.character.inventory = [
		{"item_id": "shortbow", "count": 1},
		{"item_id": "short_sword", "count": 1},
		{"item_id": "potion", "count": 1},
	]

	var armed: Combat.Resolution = _resolve(
		armed_state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_eq(armed.weapon_id, "short_sword")
	assert_eq(armed.weapon_name_ja, "試験用短剣")
	assert_eq(armed.weapon_damage, 3)
	var armed_record: Dictionary[String, Variant] = armed.to_dict()
	assert_eq(armed_record["weapon_id"], "short_sword")

	var unarmed_state: GameState = _combat_state(scenario)
	unarmed_state.character.inventory = [{"item_id": "potion", "count": 1}]
	var unarmed: Combat.Resolution = _resolve(
		unarmed_state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_eq(unarmed.weapon_id, Combat.UNARMED_ID)
	assert_eq(unarmed.weapon_name_ja, "素手")
	assert_eq(unarmed.weapon_damage, 1)
	assert_eq(unarmed.damage_dealt, 1)
	assert_eq(_enemy_hp(unarmed_state, "goblin"), 3)


func test_06_zero_enemy_hp_removes_active_enemy_and_sets_defeated_flag() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	var enemy: Dictionary = state.active_enemies[0]
	var hp: Dictionary = enemy["hp"]
	hp["current"] = 1

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_true(resolution.enemy_defeated)
	assert_eq(state.active_enemies.size(), 0)
	assert_eq(state.flags.get("defeated_goblin"), true)
	assert_true(_contains_text(resolution.applied_effects, "defeated_goblin"))


func test_07_zero_pc_hp_confirms_incapacitation_and_applies_on_defeat() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.hp = {"current": 1, "max": 8}

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.FAILURE,
	)

	assert_true(resolution.success)
	assert_true(resolution.incapacitated)
	assert_eq(state.character.hp["current"], 0)
	assert_eq(state.flags.get("incapacitated"), true)
	assert_eq(state.scene_id, "rescue")
	assert_eq(state.active_enemies.size(), 0)
	assert_true(_contains_text(resolution.applied_effects, "on_defeat"))


func test_07b_existing_zero_hp_does_not_reapply_on_defeat_without_new_damage() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.hp["current"] = 0

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_true(resolution.success)
	assert_false(resolution.incapacitated)
	assert_false(state.flags.has("incapacitated"))
	assert_eq(state.scene_id, "entrance")
	assert_false(_contains_text(resolution.applied_effects, "on_defeat"))


func test_08_attack_turn_applies_and_saves_damage_in_committing_before_narrating() -> void:
	var backend: RecordingBackend = RecordingBackend.new()
	backend.set_responses(
		[
			_intent_json(),
			"素手の一撃がゴブリンをよろめかせた。",
		]
	)
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	var manager: RecordingSaveManager = RecordingSaveManager.new(TEMP_ROOT)
	var machine: TurnMachine = _machine(backend, state, scenario, manager)
	var hp_at_committing: Array[int] = []
	var observations_at_narrating: Array[Dictionary] = []
	machine.state_changed.connect(
		func(_previous: int, current: int) -> void:
			if current == TurnMachine.State.COMMITTING:
				hp_at_committing.append(_enemy_hp(state, "goblin"))
			if current == TurnMachine.State.NARRATING:
				var saved_state: GameState = _load_state(manager)
				observations_at_narrating.append(
					{
						"memory_hp": _enemy_hp(state, "goblin"),
						"saved_hp": (
							-1
							if saved_state == null
							else _enemy_hp(saved_state, "goblin")
						),
						"flushed": manager.flush_completed,
					}
				)
	)

	assert_true(await machine.submit_input("ゴブリンを殴る"))

	assert_true(
		_has_state_subsequence(
			machine.state_history,
			[
				TurnMachine.State.CLASSIFYING,
				TurnMachine.State.VALIDATING,
				TurnMachine.State.ROLLING,
				TurnMachine.State.COMMITTING,
				TurnMachine.State.NARRATING,
			],
		)
	)
	assert_eq(hp_at_committing, [4], "敵HPがCOMMITTINGより前に変化しています。")
	assert_eq(observations_at_narrating.size(), 1)
	if observations_at_narrating.size() == 1:
		assert_eq(observations_at_narrating[0]["memory_hp"], 2)
		assert_eq(observations_at_narrating[0]["saved_hp"], 2)
		assert_eq(observations_at_narrating[0]["flushed"], true)
	assert_not_null(machine.last_combat_resolution)
	if machine.last_combat_resolution != null:
		assert_eq(machine.last_combat_resolution.branch, "CRITICAL")
		assert_eq(machine.last_combat_resolution.weapon_id, Combat.UNARMED_ID)
		assert_eq(machine.last_combat_resolution.damage_dealt, 2)
	assert_gte(manager.saved_snapshots.size(), 2)
	if not manager.saved_snapshots.is_empty():
		var pending: Dictionary = manager.saved_snapshots[0]["pending_narration"]
		var confirmed: Dictionary = pending["confirmed_result"]
		var weapon: Dictionary = confirmed["weapon"]
		assert_eq(weapon["id"], Combat.UNARMED_ID)
		assert_eq(confirmed["damage_dealt"], 2)
		assert_eq(confirmed["combat_branch"], "CRITICAL")


func test_09_narrating_preserves_game_state_hash_including_enemy_hp() -> void:
	var backend: RecordingBackend = RecordingBackend.new()
	backend.set_responses(
		[
			_intent_json(),
			"ゴブリンは一撃を受け、それでも踏みとどまった。",
		]
	)
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	var machine: TurnMachine = _machine(
		backend,
		state,
		scenario,
		RecordingSaveManager.new(TEMP_ROOT),
	)
	var hashes: Array[String] = []
	machine.state_changed.connect(
		func(_previous: int, current: int) -> void:
			if current == TurnMachine.State.NARRATING:
				hashes.append(JSON.stringify(state.serialize(), "", true))
	)
	machine.narration_finished.connect(
		func(_text: String) -> void:
			hashes.append(JSON.stringify(state.serialize(), "", true))
	)

	assert_true(await machine.submit_input("ゴブリンを殴る"))

	assert_eq(hashes.size(), 2)
	if hashes.size() == 2:
		assert_eq(
			hashes[1],
			hashes[0],
			"NARRATING前後で敵HPを含むGameStateが変化しています（INV-1）。",
		)


func test_10_scene_entry_expands_enemy_ids_from_master_data() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = GameState.new()

	var errors: Array[String] = scenario.enter_scene("entrance", state)

	assert_true(errors.is_empty(), str(errors))
	assert_eq(state.scene_id, "entrance")
	assert_eq(state.active_enemies.size(), 1)
	assert_eq(state.active_enemies[0]["enemy_id"], "goblin")
	assert_eq(_enemy_hp(state, "goblin"), 4)

	assert_true(scenario.enter_scene("rescue", state).is_empty())
	assert_eq(state.active_enemies.size(), 0)


func test_11_combat_effect_log_uses_enemy_display_name() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)

	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.SUCCESS,
	)

	assert_true(_contains_text(resolution.applied_effects, "ゴブリン"))
	assert_false(_contains_text(resolution.applied_effects, "enemy:goblin"))


func test_12_ui_outcome_contains_weapon_damage_branch_and_effects() -> void:
	var scenario: Scenario = _fixture()
	var state: GameState = _combat_state(scenario)
	state.character.inventory = [{"item_id": "shortbow", "count": 1}]
	var resolution: Combat.Resolution = _resolve(
		state,
		scenario,
		Types.ResultTier.SUCCESS,
	)
	var backend: RecordingBackend = RecordingBackend.new()
	var machine: TurnMachine = _machine(
		backend,
		state,
		scenario,
		RecordingSaveManager.new(TEMP_ROOT),
	)
	machine.last_combat_resolution = resolution
	var screen: MainScreen = MainScreen.new()
	screen._machine = machine

	var outcome: String = screen._judgment_outcome()

	assert_true(outcome.contains("試験用短弓"))
	assert_true(outcome.contains("SUCCESS"))
	assert_true(outcome.contains("与ダメージ: 2"))
	assert_true(outcome.contains("敵「ゴブリン」へ2ダメージ"))
	screen.free()


func _resolve(
	state: GameState,
	scenario: Scenario,
	tier: Types.ResultTier,
) -> Combat.Resolution:
	return _resolve_with_seed(state, scenario, tier, 1600)


func _resolve_with_seed(
	state: GameState,
	scenario: Scenario,
	tier: Types.ResultTier,
	seed_value: int,
) -> Combat.Resolution:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var judgment: Judgment.Result = Judgment.Result.new()
	judgment.tier = tier
	return Combat.resolve(
		{
			"action_type": "attack",
			"ability": "STR",
			"target": "enemy:goblin",
		},
		judgment,
		state,
		scenario,
		rng,
		ITEMS_FIXTURE,
	)


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "フィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


func _combat_state(scenario: Scenario) -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.character.hp = {"current": 8, "max": 8}
	var errors: Array[String] = scenario.enter_scene("entrance", state)
	assert_true(errors.is_empty(), "戦闘シーンへ進入できません: %s" % str(errors))
	return state


func _machine(
	backend: LLMBackend,
	state: GameState,
	scenario: Scenario,
	manager: SaveManager,
) -> TurnMachine:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = SEED_CRITICAL
	return TurnMachine.new(
		backend,
		state,
		scenario,
		manager,
		SLOT,
		rng,
		ITEMS_FIXTURE,
	)


func _load_state(manager: SaveManager) -> GameState:
	var load_result: SaveManager.LoadResult = manager.load(SLOT)
	if not load_result.is_success():
		fail_test("保存済みGameStateをロードできません: %s" % str(load_result.errors))
		return null
	var state_result: GameState.LoadResult = GameState.deserialize(load_result.data)
	if not state_result.is_success():
		fail_test("保存済みGameStateを復元できません: %s" % str(state_result.errors))
		return null
	return state_result.state


func _enemy_hp(state: GameState, enemy_id: String) -> int:
	for enemy: Dictionary in state.active_enemies:
		if String(enemy.get("enemy_id", "")) != enemy_id:
			continue
		var hp: Dictionary = enemy.get("hp", {})
		return int(hp.get("current", -1))
	return -1


func _item_count(state: GameState, item_id: String) -> int:
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			return int(item.get("count", 0))
	return 0


func _contains_text(values: Array[String], fragment: String) -> bool:
	for value: String in values:
		if value.contains(fragment):
			return true
	return false


func _intent_json() -> String:
	return JSON.stringify(
		{
			"action_type": "attack",
			"ability": "STR",
			"skill_tags": [],
			"target": "enemy:goblin",
			"difficulty": "normal",
			"needs_roll": true,
			"summary_ja": "ゴブリンを殴る",
		}
	)


func _has_state_subsequence(history: Array[int], expected: Array[int]) -> bool:
	var expected_index: int = 0
	for value: int in history:
		if expected_index < expected.size() and value == expected[expected_index]:
			expected_index += 1
	return expected_index == expected.size()


func _cleanup() -> void:
	var slot_path: String = TEMP_ROOT.path_join("slot_%d" % SLOT)
	for file_name: String in [
		"save.json",
		"save.tmp.json",
		"save.bak1.json",
		"save.bak2.json",
		"save.pre_migration.json",
	]:
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(slot_path.path_join(file_name))
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_ROOT))
