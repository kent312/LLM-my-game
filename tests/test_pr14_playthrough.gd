class_name TestPr14Playthrough
extends GutTest

const SCENARIO_PATH: String = "res://game/data/scenarios/mist_bell/scenario.json"
const PRESET_PATH: String = "res://game/data/characters/mist_bell_scout.json"
const ITEMS_PATH: String = "res://game/data/items.json"
const TEMP_ROOT: String = "user://test_pr14_playthrough"
const SLOT: int = 14


func before_each() -> void:
	_cleanup()


func after_each() -> void:
	_cleanup()


func test_mock_script_completes_one_shot_and_persists_rewards() -> void:
	var scenario_result: Scenario.LoadResult = Scenario.load_file(SCENARIO_PATH)
	assert_true(
		scenario_result.is_success(),
		"ワンショットのロードに失敗しました: %s" % str(scenario_result.errors),
	)
	if scenario_result.scenario == null:
		return
	var scenario: Scenario = scenario_result.scenario
	var character_result: CharacterSheet.LoadResult = CharacterSheet.load(
		_read_text(PRESET_PATH)
	)
	assert_true(
		character_result.is_success(),
		"プリセットキャラクターの検証に失敗しました: %s" % str(character_result.errors),
	)
	if character_result.sheet == null:
		return

	var state: GameState = GameState.new()
	state.character = character_result.sheet
	state.scenario_id = String(scenario.data["id"])
	state.scene_id = "fog_gate"
	var starting_xp: int = state.character.xp
	var starting_money: int = state.character.money
	var backend: LLMBackend = PreviewBackendFactory.create_for_state(state)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1414
	var manager: SaveManager = SaveManager.new(TEMP_ROOT)
	var machine: TurnMachine = TurnMachine.new(
		backend,
		state,
		scenario,
		manager,
		SLOT,
		rng,
	)
	var completion_signals: Array[Dictionary] = []
	var rewards_at_final_narrating: Array[Dictionary] = []
	machine.scenario_completed.connect(
		func(xp: int, money: int) -> void:
			completion_signals.append({"xp": xp, "money": money})
	)
	machine.state_changed.connect(
		func(_previous: int, current: int) -> void:
			if (
				current != TurnMachine.State.NARRATING
				or not bool(state.flags.get("scenario_cleared", false))
			):
				return
			var committed_save: SaveManager.LoadResult = manager.load(SLOT)
			if not committed_save.is_success():
				return
			var committed_state: GameState.LoadResult = GameState.deserialize(
				committed_save.data
			)
			if committed_state.state == null:
				return
			rewards_at_final_narrating.append(
				{
					"xp": committed_state.state.character.xp,
					"money": committed_state.state.character.money,
					"pending": committed_state.state.pending_narration != null,
				}
			)
	)

	var inputs: Array[String] = [
		"霧門の刻印を調べる",
		"書架を読み、月鍵を探す",
		"星見鏡の歯車を調整する",
		"霧の残響に帰る場所を語りかける",
	]
	var expected_scenes: Array[String] = [
		"sunken_archive",
		"observatory",
		"dawn_sanctum",
		"dawn_sanctum",
	]
	for index: int in range(inputs.size()):
		var completed: bool = await machine.submit_input(inputs[index])
		assert_true(completed, "第%dターンが完了しませんでした。" % (index + 1))
		assert_not_null(machine.last_intent)
		if machine.last_intent != null:
			assert_true(
				machine.last_intent.executable,
				"preview_script.json の第%d intent が実行可能ではありません。" % (index + 1),
			)
		assert_eq(state.scene_id, expected_scenes[index])
		assert_eq(machine.current_state, TurnMachine.State.IDLE)
		if index == 0:
			assert_eq(
				machine.last_intent.ability_id,
				"STR",
				"テスト前提としてプレビュー台本はAI提案値STRである必要があります。",
			)
			assert_not_null(machine.last_judgment_request)
			if machine.last_judgment_request != null:
				assert_eq(
					machine.last_judgment_request.ability,
					Types.Ability.WIS,
					"check定義のWISがAI提案値STRより優先される必要があります。",
				)
		await get_tree().process_frame

	assert_eq(state.turn_count, 4)
	assert_eq(machine.recent_logs.size(), 4)
	assert_eq(state.flags.get("scenario_cleared"), true)
	assert_eq(state.flags.get("rewards_granted"), true)
	assert_eq(state.character.xp, starting_xp + 4)
	assert_eq(state.character.money, starting_money + 35)
	assert_eq(completion_signals, [{"xp": 4, "money": 35}])
	assert_eq(
		rewards_at_final_narrating,
		[{"xp": starting_xp + 4, "money": starting_money + 35, "pending": true}],
		"最終描写より前に報酬とpending_narrationが同じセーブへ確定される必要があります。",
	)
	assert_eq(_item_count(state, "moon_key"), 1)
	_assert_transparent_judgment_logs(
		machine.recent_logs,
		["WIS", "INT", "DEX", "CHA"],
	)

	var save_result: SaveManager.LoadResult = manager.load(SLOT)
	assert_true(
		save_result.is_success(),
		"クリア状態のセーブをロードできません: %s" % str(save_result.errors),
	)
	if not save_result.is_success():
		return
	var state_result: GameState.LoadResult = GameState.deserialize(save_result.data)
	assert_true(
		state_result.is_success(),
		"クリア状態のGameStateを復元できません: %s" % str(state_result.errors),
	)
	if state_result.state == null:
		return
	assert_eq(state_result.state.flags.get("scenario_cleared"), true)
	assert_eq(state_result.state.flags.get("rewards_granted"), true)
	assert_eq(state_result.state.character.xp, starting_xp + 4)
	assert_eq(state_result.state.character.money, starting_money + 35)
	assert_null(state_result.state.pending_narration)


func test_scenario_items_and_preset_references_exist_in_master_data() -> void:
	var items_value: Variant = JSON.parse_string(_read_text(ITEMS_PATH))
	assert_eq(typeof(items_value), TYPE_DICTIONARY)
	if typeof(items_value) != TYPE_DICTIONARY:
		return
	var items_root: Dictionary = items_value
	var item_ids: Dictionary[String, bool] = {}
	var items_value_array: Variant = items_root.get("items", [])
	assert_eq(typeof(items_value_array), TYPE_ARRAY)
	if typeof(items_value_array) != TYPE_ARRAY:
		return
	var items: Array = items_value_array
	for item_value: Variant in items:
		if typeof(item_value) == TYPE_DICTIONARY:
			var item: Dictionary = item_value
			item_ids[String(item.get("id", ""))] = true
	for expected_id: String in ["torch", "potion", "moon_key"]:
		assert_true(item_ids.has(expected_id), "items.json に %s がありません。" % expected_id)

	var character_result: CharacterSheet.LoadResult = CharacterSheet.load(
		_read_text(PRESET_PATH)
	)
	assert_true(character_result.is_success(), str(character_result.errors))
	if character_result.sheet == null:
		return
	assert_eq(character_result.sheet.skills.size(), 2, "固定スキルは2つである必要があります。")
	var ability_total: int = 0
	var minus_one_count: int = 0
	for ability_id: String in CharacterSheet.ABILITY_IDS:
		var ability_value: int = int(character_result.sheet.abilities[ability_id])
		ability_total += ability_value
		if ability_value == -1:
			minus_one_count += 1
	assert_eq(ability_total, 5, "プリセットの能力値配分が作成ルールと一致しません。")
	assert_eq(minus_one_count, 1)
	assert_true(_character_has_tag(character_result.sheet, "skill.craft"))
	assert_true(_character_has_tag(character_result.sheet, "skill.persuasion"))
	for inventory_item: Dictionary in character_result.sheet.inventory:
		assert_true(
			item_ids.has(String(inventory_item.get("item_id", ""))),
			"プリセットが未定義アイテムを参照しています。",
		)


func test_rescue_scene_has_a_deterministic_route_back_to_the_finale() -> void:
	var scenario_result: Scenario.LoadResult = Scenario.load_file(SCENARIO_PATH)
	assert_true(scenario_result.is_success(), str(scenario_result.errors))
	if scenario_result.scenario == null:
		return
	var rescue: Dictionary = {}
	var scenes: Array = scenario_result.scenario.data.get("scenes", [])
	for scene_value: Variant in scenes:
		if typeof(scene_value) != TYPE_DICTIONARY:
			continue
		var scene: Dictionary = scene_value
		if String(scene.get("id", "")) == "rescue":
			rescue = scene
			break
	assert_false(rescue.is_empty(), "救済シーン rescue が必要です。")
	if rescue.is_empty():
		return
	var checks: Array = rescue.get("checks", [])
	var exits: Array = rescue.get("exits", [])
	assert_false(checks.is_empty(), "rescue に復帰判定が必要です。")
	assert_false(exits.is_empty(), "rescue に復帰用出口が必要です。")
	if checks.is_empty():
		return
	var recovery_check: Dictionary = checks[0]
	for branch_name: String in ["on_success", "on_partial", "on_failure"]:
		var branch: Dictionary = recovery_check.get(branch_name, {})
		assert_eq(
			String(branch.get("goto", "")),
			"dawn_sanctum",
			"rescue の全tierが最終場面へ復帰する必要があります。",
		)


func _assert_transparent_judgment_logs(
	logs: Array[String],
	expected_abilities: Array[String],
) -> void:
	for index: int in range(logs.size()):
		var parsed: Variant = JSON.parse_string(logs[index])
		assert_eq(typeof(parsed), TYPE_DICTIONARY)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var log: Dictionary = parsed
		var judgment_value: Variant = log.get("judgment", {})
		assert_eq(typeof(judgment_value), TYPE_DICTIONARY)
		if typeof(judgment_value) != TYPE_DICTIONARY:
			continue
		var judgment: Dictionary = judgment_value
		for field_name: String in [
			"ability",
			"roll_mode",
			"dice",
			"kept",
			"ability_mod",
			"skill_bonus",
			"applied_tag",
			"rejected_tags",
			"situation_mod",
			"total",
			"tier",
		]:
			assert_true(
				judgment.has(field_name),
				"第%dターンの判定ログに %s がありません。" % [index + 1, field_name],
			)
		assert_eq(
			String(judgment.get("ability", "")),
			expected_abilities[index],
			"永続ログには実際に振ったcheck定義側の能力値が必要です。",
		)


func _item_count(state: GameState, item_id: String) -> int:
	for item: Dictionary in state.character.inventory:
		if String(item.get("item_id", "")) == item_id:
			return int(item.get("count", 0))
	return 0


func _character_has_tag(character: CharacterSheet, tag_id: String) -> bool:
	if character.skills.has(tag_id):
		return true
	for specialty: Dictionary in character.specialties:
		var tags_value: Variant = specialty.get("tags", [])
		if typeof(tags_value) != TYPE_ARRAY:
			continue
		var tags: Array = tags_value
		if tags.has(tag_id):
			return true
	return false


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _cleanup() -> void:
	var slot_path: String = TEMP_ROOT.path_join("slot_%d" % SLOT)
	for file_name: String in [
		"save.json",
		"save.tmp.json",
		"save.bak1.json",
		"save.bak2.json",
	]:
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(slot_path.path_join(file_name))
		)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_ROOT))
