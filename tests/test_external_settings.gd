extends GutTest

const SETTINGS_PATH: String = "user://test_external_settings/settings.json"
const FIXTURE_PATH: String = "res://game/data/scenarios/test_fixture/scenario.json"
const TEMP_SAVE_ROOT: String = "user://test_external_settings/saves"
const API_KEY: String = "sk-test-secret-value"


func before_each() -> void:
	_cleanup()


func after_each() -> void:
	_cleanup()


func test_01_consent_is_required_before_endpoint_or_api_key_can_be_saved() -> void:
	var store: ExternalSettingsStore = ExternalSettingsStore.new(SETTINGS_PATH)
	var result: ExternalSettingsStore.SaveResult = store.save_settings(
		{
			"connection_mode": ExternalSettingsStore.MODE_CLOUD_API,
			"external_enabled": true,
			"endpoint": "https://example.invalid",
			"api_key": API_KEY,
			"model": "test-model",
			"privacy_consent": false,
		}
	)

	assert_false(result.is_success())
	assert_true(
		"\n".join(result.errors).contains("明示同意"),
		"同意不足を明示する必要があります: %s" % str(result.errors),
	)
	assert_false(FileAccess.file_exists(SETTINGS_PATH))


func test_02_payload_builder_copies_only_the_context_allowlist() -> void:
	var opts: LLMBackend.GenOpts = LLMBackend.GenOpts.new()
	opts.max_tokens = 123
	var payload: Dictionary[String, Variant] = BackendOpenAI.build_inference_payload(
		{
			"system_prompt": "安全なシステム指示",
			"character_sheet_summary": "旅人の要約",
			"current_scene": "霧の門",
			"conversation_history": "直近の会話",
			"conversation_summary": "過去の要約",
			"player_input": "門を調べる",
			"save_data": "SAVE_DATA_MUST_NOT_LEAVE",
			"steam_account": "STEAM_ACCOUNT_MUST_NOT_LEAVE",
			"hardware_info": "HARDWARE_INFO_MUST_NOT_LEAVE",
			"api_key": API_KEY,
		},
		opts,
		"test-model",
	)
	var serialized: String = JSON.stringify(payload)

	assert_false(bool(payload["stream"]))
	assert_eq(int(payload["max_tokens"]), 123)
	assert_true(serialized.contains("安全なシステム指示"))
	assert_true(serialized.contains("旅人の要約"))
	assert_true(serialized.contains("霧の門"))
	assert_true(serialized.contains("直近の会話"))
	assert_true(serialized.contains("過去の要約"))
	assert_true(serialized.contains("門を調べる"))
	assert_false(serialized.contains("SAVE_DATA_MUST_NOT_LEAVE"))
	assert_false(serialized.contains("STEAM_ACCOUNT_MUST_NOT_LEAVE"))
	assert_false(serialized.contains("HARDWARE_INFO_MUST_NOT_LEAVE"))
	assert_false(serialized.contains(API_KEY))


func test_03_api_key_is_excluded_from_save_and_export_data() -> void:
	var store: ExternalSettingsStore = ExternalSettingsStore.new(SETTINGS_PATH)
	var settings: Dictionary[String, Variant] = {
		"connection_mode": ExternalSettingsStore.MODE_CLOUD_API,
		"external_enabled": true,
		"endpoint": "https://example.invalid",
		"api_key": API_KEY,
		"model": "test-model",
		"privacy_consent": true,
	}
	var saved: ExternalSettingsStore.SaveResult = store.save_settings(settings)
	var public_export: Dictionary[String, Variant] = store.export_public_settings(settings)
	var state: GameState = GameState.new()
	state.scenario_id = "privacy-test"
	state.scene_id = "scene"
	var save_data: String = JSON.stringify(state.serialize())
	var export_data: String = JSON.stringify(public_export)

	assert_true(saved.is_success(), str(saved.errors))
	assert_false(save_data.contains(API_KEY))
	assert_false(export_data.contains(API_KEY))
	assert_false(public_export.has("api_key"))
	assert_false(public_export.has("privacy_consent"))
	var settings_file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	assert_not_null(settings_file)
	if settings_file != null:
		# Godot単体実装では平文保存であることをUIに明示する契約の確認。
		assert_true(settings_file.get_as_text().contains(API_KEY))


func test_04_indicator_is_visible_only_while_external_connection_is_active() -> void:
	var indicator: ExternalConnectionIndicator = ExternalConnectionIndicator.new()
	add_child_autofree(indicator)
	var bundled: Dictionary[String, Variant] = (
		ExternalSettingsStore.new(SETTINGS_PATH).default_settings()
	)
	indicator.apply_settings(bundled)
	assert_false(indicator.visible)
	assert_eq(indicator.text, "")

	var external_local: Dictionary[String, Variant] = {
		"connection_mode": ExternalSettingsStore.MODE_EXTERNAL_LOCAL,
		"external_enabled": true,
		"endpoint": "http://127.0.0.1:11434",
		"api_key": "",
		"model": "local-model",
		"privacy_consent": true,
	}
	indicator.apply_settings(external_local)
	assert_true(indicator.visible)
	assert_true(indicator.text.contains("外部AI接続中"))
	assert_true(indicator.text.contains("外部ローカルLLM"))

	var cloud: Dictionary[String, Variant] = external_local.duplicate(true)
	cloud["connection_mode"] = ExternalSettingsStore.MODE_CLOUD_API
	indicator.apply_settings(cloud)
	assert_true(indicator.visible)
	assert_true(indicator.text.contains("クラウドAPI"))

	indicator.apply_fallback_state(true, cloud)
	assert_true(indicator.visible)
	assert_true(indicator.text.contains("同梱モデルへ一時切替中"))
	indicator.apply_fallback_state(false, cloud)
	assert_true(indicator.visible)
	assert_true(indicator.text.contains("外部AI接続中"))
	assert_true(indicator.text.contains("クラウドAPI"))


func test_05_missing_settings_selects_offline_backend_without_http_attempt() -> void:
	var store: ExternalSettingsStore = ExternalSettingsStore.new(SETTINGS_PATH)
	var loaded: ExternalSettingsStore.LoadResult = store.load_settings()
	var request_calls: Array[Dictionary] = []
	var sender: Callable = func(payload: Dictionary) -> Dictionary:
		request_calls.append(payload)
		return {"status_code": 200, "body": _completion_body("到達してはならない")}
	var backend: LLMBackend = ExternalBackendFactory.create_for_state(
		loaded.settings,
		_offline_state(),
		sender,
	)
	var root: Window = get_tree().root
	var http_nodes_before: int = _http_request_node_count(root)
	var machine: TurnMachine = TurnMachine.new(
		backend,
		_offline_state(),
		_fixture(),
		SaveManager.new(TEMP_SAVE_ROOT),
		15,
	)

	assert_true(loaded.is_success())
	assert_false(ExternalSettingsStore.is_external_active(loaded.settings))
	assert_false(backend is BackendOpenAI)
	assert_false(await machine.submit_input("既定オフラインで周囲を見る"))
	assert_eq(request_calls.size(), 0)
	assert_eq(_http_request_node_count(root), http_nodes_before)


func test_06_consent_notice_contains_all_required_disclosures() -> void:
	var dialog: ExternalSettingsDialog = ExternalSettingsDialog.new(
		ExternalSettingsStore.new(SETTINGS_PATH)
	)
	add_child_autofree(dialog)
	var notice: String = dialog.consent_notice("https://api.example.invalid")

	assert_true(notice.contains("システムプロンプト"))
	assert_true(notice.contains("キャラシート要約"))
	assert_true(notice.contains("現在シーン情報"))
	assert_true(notice.contains("会話履歴または要約"))
	assert_true(notice.contains("プレイヤー入力"))
	assert_true(notice.contains("https://api.example.invalid"))
	assert_true(notice.contains("ゲームの管理外"))
	assert_true(notice.contains("利用規約"))
	assert_true(notice.contains("年齢制限"))
	assert_true(notice.contains("平文"))


func test_07_settings_schema_matches_store_keys_version_and_modes() -> void:
	var schema_file: FileAccess = FileAccess.open(
		"res://game/data/settings_schema.json",
		FileAccess.READ,
	)
	assert_not_null(schema_file)
	if schema_file == null:
		return
	var parsed: Variant = JSON.parse_string(schema_file.get_as_text())
	assert_eq(typeof(parsed), TYPE_DICTIONARY)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var schema: Dictionary = parsed
	var required: Array = schema["required"]
	var store_keys: Array = ExternalSettingsStore.new(SETTINGS_PATH).default_settings().keys()
	required.sort()
	store_keys.sort()
	assert_eq(required, store_keys)
	var properties: Dictionary = schema["properties"]
	var version_schema: Dictionary = properties["schema_version"]
	assert_eq(int(version_schema["const"]), ExternalSettingsStore.SCHEMA_VERSION)
	var mode_schema: Dictionary = properties["connection_mode"]
	var schema_modes: Array = mode_schema["enum"]
	schema_modes.sort()
	var store_modes: Array[String] = [
		ExternalSettingsStore.MODE_BUNDLED,
		ExternalSettingsStore.MODE_CLOUD_API,
		ExternalSettingsStore.MODE_EXTERNAL_LOCAL,
	]
	store_modes.sort()
	assert_eq(schema_modes, store_modes)
	assert_false(bool(schema["additionalProperties"]))
	var defaults: Dictionary[String, Variant] = (
		ExternalSettingsStore.new(SETTINGS_PATH).default_settings()
	)
	for property_name: String in defaults:
		var property_schema: Dictionary = properties[property_name]
		if property_schema.has("type"):
			assert_eq(
				String(property_schema["type"]),
				_json_type_name(defaults[property_name]),
				"設定キー%sの型がスキーマと保存層で一致しません。" % property_name,
			)
	var store: ExternalSettingsStore = ExternalSettingsStore.new(SETTINGS_PATH)
	var invalid_mode: Dictionary[String, Variant] = defaults.duplicate(true)
	invalid_mode["connection_mode"] = "unknown"
	assert_false(store.save_settings(invalid_mode).is_success())
	var invalid_version: Dictionary[String, Variant] = defaults.duplicate(true)
	invalid_version["schema_version"] = 999
	assert_false(store.save_settings(invalid_version).is_success())


func _completion_body(text: String) -> String:
	return JSON.stringify(
		{"choices": [{"message": {"content": text}}]}
	)


func _fixture() -> Scenario:
	var result: Scenario.LoadResult = Scenario.load_file(FIXTURE_PATH)
	assert_true(result.is_success(), "フィクスチャをロードできません: %s" % str(result.errors))
	return result.scenario


func _offline_state() -> GameState:
	var state: GameState = GameState.new()
	state.scenario_id = "test_fixture"
	state.scene_id = "entrance"
	return state


func _http_request_node_count(root: Node) -> int:
	var count: int = 0
	for child: Node in root.get_children():
		if child.get_class() == "HTTPRequest": # INV4_ALLOW_NETWORK_TEST: ノード不生成を検査。
			count += 1
	return count


func _json_type_name(value: Variant) -> String:
	match typeof(value):
		TYPE_BOOL:
			return "boolean"
		TYPE_INT:
			return "integer"
		TYPE_STRING:
			return "string"
		_:
			return ""


func _cleanup() -> void:
	var absolute_directory: String = ProjectSettings.globalize_path(
		SETTINGS_PATH.get_base_dir()
	)
	if DirAccess.dir_exists_absolute(absolute_directory):
		_remove_directory_contents(absolute_directory)
		DirAccess.remove_absolute(absolute_directory)


func _remove_directory_contents(directory_path: String) -> void:
	var directory: DirAccess = DirAccess.open(directory_path)
	if directory == null:
		return
	directory.list_dir_begin()
	var entry: String = directory.get_next()
	while not entry.is_empty():
		var child_path: String = directory_path.path_join(entry)
		if directory.current_is_dir():
			_remove_directory_contents(child_path)
			DirAccess.remove_absolute(child_path)
		else:
			DirAccess.remove_absolute(child_path)
		entry = directory.get_next()
	directory.list_dir_end()
