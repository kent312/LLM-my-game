class_name ExternalSettingsStore
extends RefCounted

const SETTINGS_PATH: String = "user://settings.json"
const SCHEMA_VERSION: int = 1
const MODE_BUNDLED: String = "bundled"
const MODE_EXTERNAL_LOCAL: String = "external_local"
const MODE_CLOUD_API: String = "cloud_api"
const EXTERNAL_MODES: Array[String] = [MODE_EXTERNAL_LOCAL, MODE_CLOUD_API]


class SaveResult:
	var errors: Array[String] = []


	func is_success() -> bool:
		return errors.is_empty()


class LoadResult:
	var settings: Dictionary[String, Variant] = {}
	var errors: Array[String] = []


	func is_success() -> bool:
		return errors.is_empty()


var settings_path: String


func _init(path: String = SETTINGS_PATH) -> void:
	settings_path = path


func default_settings() -> Dictionary[String, Variant]:
	return {
		"schema_version": SCHEMA_VERSION,
		"connection_mode": MODE_BUNDLED,
		"external_enabled": false,
		"endpoint": "",
		"api_key": "",
		"model": "",
		"privacy_consent": false,
	}


func load_settings() -> LoadResult:
	var result: LoadResult = LoadResult.new()
	result.settings = default_settings()
	if not FileAccess.file_exists(settings_path):
		# INV-4: 設定ファイルがない初回起動は必ず同梱モデルで開始する。
		return result
	var file: FileAccess = FileAccess.open(settings_path, FileAccess.READ)
	if file == null:
		result.errors.append(
			tr("外部接続設定を読み込めません: %s")
			% error_string(FileAccess.get_open_error())
		)
		return result
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		result.errors.append(tr("外部接続設定のJSON形式が不正です。"))
		return result
	var source: Dictionary = parsed
	var normalized: Dictionary[String, Variant] = _normalize(source)
	var validation_errors: Array[String] = _validate(normalized)
	if not validation_errors.is_empty():
		result.errors.append_array(validation_errors)
		return result
	result.settings = normalized
	return result


func save_settings(candidate: Dictionary) -> SaveResult:
	var result: SaveResult = SaveResult.new()
	var normalized: Dictionary[String, Variant] = _normalize(candidate)
	result.errors.append_array(_validate(normalized))
	if not result.errors.is_empty():
		return result
	var directory_path: String = settings_path.get_base_dir()
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(directory_path)
	)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		result.errors.append(
			tr("外部接続設定の保存先を作成できません: %s")
			% error_string(directory_error)
		)
		return result
	var file: FileAccess = FileAccess.open(settings_path, FileAccess.WRITE)
	if file == null:
		result.errors.append(
			tr("外部接続設定を保存できません: %s")
			% error_string(FileAccess.get_open_error())
		)
		return result
	# Godot単体には各OSの資格情報ストアを共通利用するAPIがない。PR-15では
	# settings.jsonへの平文保存を採用し、設定画面で保存前に必ず明示する。
	# 将来ネイティブ連携を追加しても、セーブ/エクスポートへ混ぜない境界は維持する。
	file.store_string(JSON.stringify(normalized, "\t", false))
	return result


func export_public_settings(settings: Dictionary) -> Dictionary[String, Variant]:
	var normalized: Dictionary[String, Variant] = _normalize(settings)
	normalized.erase("api_key")
	normalized.erase("privacy_consent")
	return normalized


static func is_external_active(settings: Dictionary) -> bool:
	var mode: String = String(settings.get("connection_mode", MODE_BUNDLED))
	return (
		EXTERNAL_MODES.has(mode)
		and bool(settings.get("external_enabled", false))
		and bool(settings.get("privacy_consent", false))
		and not String(settings.get("endpoint", "")).strip_edges().is_empty()
	)


func _normalize(source: Dictionary) -> Dictionary[String, Variant]:
	var mode: String = String(source.get("connection_mode", MODE_BUNDLED))
	var external: bool = mode != MODE_BUNDLED
	return {
		"schema_version": int(source.get("schema_version", SCHEMA_VERSION)),
		"connection_mode": mode,
		"external_enabled": bool(source.get("external_enabled", external)),
		"endpoint": String(source.get("endpoint", "")).strip_edges(),
		"api_key": String(source.get("api_key", "")),
		"model": String(source.get("model", "")).strip_edges(),
		"privacy_consent": bool(source.get("privacy_consent", false)),
	}


func _validate(settings: Dictionary[String, Variant]) -> Array[String]:
	var errors: Array[String] = []
	var mode: String = String(settings["connection_mode"])
	if int(settings["schema_version"]) != SCHEMA_VERSION:
		errors.append(tr("外部接続設定のスキーマ版に対応していません。"))
	if not [MODE_BUNDLED, MODE_EXTERNAL_LOCAL, MODE_CLOUD_API].has(mode):
		errors.append(tr("外部接続設定の接続モードが不正です。"))
		return errors
	if mode == MODE_BUNDLED:
		# 同梱モードへ戻す際に古い秘密情報を温存しない。
		settings["external_enabled"] = false
		settings["endpoint"] = ""
		settings["api_key"] = ""
		settings["model"] = ""
		settings["privacy_consent"] = false
		return errors
	if not bool(settings["privacy_consent"]):
		errors.append(tr("明示同意なしでは送信先やAPIキーを保存できません。"))
	if not bool(settings["external_enabled"]):
		errors.append(tr("外部接続設定を保存するには外部接続を有効にしてください。"))
	var endpoint: String = String(settings["endpoint"])
	if endpoint.is_empty():
		errors.append(tr("送信先エンドポイントを入力してください。"))
	elif not endpoint.begins_with("http://") and not endpoint.begins_with("https://"):
		errors.append(
			tr("送信先エンドポイントは http:// または https:// で始めてください。")
		)
	if mode == MODE_CLOUD_API and String(settings["api_key"]).is_empty():
		errors.append(tr("クラウドAPIにはAPIキーが必要です。"))
	return errors
