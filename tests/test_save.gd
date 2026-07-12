extends GutTest

const TEMP_ROOT: String = "user://test_save_manager"
const SLOT: int = 1

var manager: SaveManager


func before_each() -> void:
	_cleanup()
	manager = SaveManager.new(TEMP_ROOT)


func after_each() -> void:
	_cleanup()


func test_save_and_load_round_trip_restores_game_state() -> void:
	var state: GameState = _state(7)
	state.flags = {"opened": true, "count": 2, "note": "済"}
	state.active_enemies = [{"enemy_id": "goblin", "hp": {"current": 3, "max": 4}}]
	state.pending_narration = {"kind": "check", "tier": "partial"}

	var save_result: SaveManager.SaveResult = manager.save(SLOT, state.serialize())
	var load_result: SaveManager.LoadResult = manager.load(SLOT)

	assert_true(save_result.is_success(), "保存に失敗しました: %s" % str(save_result.errors))
	assert_true(load_result.is_success(), "ロードに失敗しました: %s" % str(load_result.errors))
	var state_result: GameState.LoadResult = GameState.deserialize(load_result.data)
	assert_true(state_result.is_success(), "GameState の復元に失敗しました: %s" % str(state_result.errors))
	if state_result.state != null:
		assert_eq(state_result.state.serialize(), state.serialize())


func test_checksum_tampering_falls_back_to_backup_one() -> void:
	var first: Dictionary[String, Variant] = _state(1).serialize()
	var second: Dictionary[String, Variant] = _state(2).serialize()
	assert_true(manager.save(SLOT, first).is_success())
	assert_true(manager.save(SLOT, second).is_success())

	var save_path: String = _file_path("save.json")
	var document: Dictionary = _read_document(save_path)
	var data: Dictionary = document["data"]
	data["turn_count"] = 999
	assert_eq(_write_document(save_path, document), OK)

	var result: SaveManager.LoadResult = manager.load(SLOT)

	assert_true(result.is_success(), "バックアップへのフォールバックに失敗しました: %s" % str(result.errors))
	assert_true(result.used_fallback)
	assert_eq(result.source, "save.bak1.json")
	assert_eq(_restore_data(result.data), first)
	assert_true(_contains(result.warnings, "checksum"))
	assert_true(_contains(result.warnings, "フォールバック"))


func test_all_three_crash_windows_recover_the_last_confirmed_state() -> void:
	# 手順1後: save.json は move されず、旧確定状態をそのままロードできる。
	var old_data: Dictionary[String, Variant] = _state(10).serialize()
	var new_data: Dictionary[String, Variant] = _state(11).serialize()
	assert_true(manager.save(SLOT, old_data).is_success())
	assert_true(manager._rotate_backups(SLOT).is_empty())
	var after_rotation: SaveManager.LoadResult = manager.load(SLOT)
	assert_true(after_rotation.is_success())
	assert_eq(_restore_data(after_rotation.data), old_data)
	assert_eq(after_rotation.source, "save.json")

	# 手順2後: flush 済み tmp が新しい確定状態として昇格される。
	_cleanup()
	manager = SaveManager.new(TEMP_ROOT)
	assert_true(manager.save(SLOT, old_data).is_success())
	assert_true(manager._rotate_backups(SLOT).is_empty())
	assert_true(manager._write_temporary(SLOT, new_data).is_empty())
	var after_temporary_write: SaveManager.LoadResult = manager.load(SLOT)
	assert_true(after_temporary_write.is_success())
	assert_eq(_restore_data(after_temporary_write.data), new_data)
	assert_true(after_temporary_write.promoted_temporary)
	assert_eq(after_temporary_write.source, "save.tmp.json")
	assert_true(FileAccess.file_exists(_file_path("save.json")))
	assert_false(FileAccess.file_exists(_file_path("save.tmp.json")))

	# 手順3後: 原子的置換済みの新しい save.json をロードする。
	_cleanup()
	manager = SaveManager.new(TEMP_ROOT)
	assert_true(manager.save(SLOT, old_data).is_success())
	assert_true(manager._rotate_backups(SLOT).is_empty())
	assert_true(manager._write_temporary(SLOT, new_data).is_empty())
	assert_true(manager._replace_with_temporary(SLOT).is_empty())
	var after_replace: SaveManager.LoadResult = manager.load(SLOT)
	assert_true(after_replace.is_success())
	assert_eq(_restore_data(after_replace.data), new_data)
	assert_false(after_replace.promoted_temporary)
	assert_eq(after_replace.source, "save.json")


func test_three_saves_rotate_backup_generations() -> void:
	var first: Dictionary[String, Variant] = _state(1).serialize()
	var second: Dictionary[String, Variant] = _state(2).serialize()
	var third: Dictionary[String, Variant] = _state(3).serialize()

	assert_true(manager.save(SLOT, first).is_success())
	assert_true(manager.save(SLOT, second).is_success())
	assert_true(manager.save(SLOT, third).is_success())

	assert_eq(_saved_data("save.json"), third)
	assert_eq(_saved_data("save.bak1.json"), second)
	assert_eq(_saved_data("save.bak2.json"), first)


func test_unknown_schema_version_is_an_error() -> void:
	assert_true(manager.save(SLOT, _state(1).serialize()).is_success())
	var save_path: String = _file_path("save.json")
	var document: Dictionary = _read_document(save_path)
	document["schema_version"] = 999
	assert_eq(_write_document(save_path, document), OK)

	var result: SaveManager.LoadResult = manager.load(SLOT)

	assert_false(result.is_success())
	assert_true(_contains(result.errors, "schema_version"))
	assert_true(_contains(result.errors, "未知のバージョン 999"))


func _state(turn_count: int) -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	state.clock = turn_count
	state.turn_count = turn_count
	return state


func _saved_data(file_name: String) -> Dictionary:
	var document: Dictionary = _read_document(_file_path(file_name))
	var data: Dictionary = document.get("data", {})
	return _restore_data(data)


func _restore_data(data: Dictionary) -> Dictionary:
	var result: GameState.LoadResult = GameState.deserialize(data)
	if not result.is_success() or result.state == null:
		fail_test("保存内容から GameState を復元できません: %s" % str(result.errors))
		return {}
	return result.state.serialize()


func _read_document(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		fail_test("ファイルを開けません: %s（%s）" % [path, error_string(FileAccess.get_open_error())])
		return {}
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(file.get_as_text())
	file.close()
	if parse_error != OK or typeof(json.data) != TYPE_DICTIONARY:
		fail_test("保存文書のJSONを解析できません: %s" % path)
		return {}
	return json.data


func _write_document(path: String, document: Dictionary) -> Error:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(document, "\t", false, true) + "\n")
	file.flush()
	var result: Error = file.get_error()
	file.close()
	return result


func _file_path(file_name: String) -> String:
	return TEMP_ROOT.path_join("slot_%d" % SLOT).path_join(file_name)


func _contains(messages: Array[String], fragment: String) -> bool:
	for message: String in messages:
		if message.contains(fragment):
			return true
	return false


func _cleanup() -> void:
	var slot_path: String = TEMP_ROOT.path_join("slot_%d" % SLOT)
	for file_name: String in [
		"save.json",
		"save.tmp.json",
		"save.bak1.json",
		"save.bak2.json",
		"save.pre_migration.json",
	]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path.path_join(file_name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEMP_ROOT))
