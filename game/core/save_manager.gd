class_name SaveManager

const CURRENT_SCHEMA_VERSION: int = 1
const DEFAULT_ROOT_PATH: String = "user://saves"

var root_path: String


class SaveResult:
	var errors: Array[String]


	func _init(save_errors: Array[String]) -> void:
		errors = save_errors.duplicate()


	func is_success() -> bool:
		return errors.is_empty()


class LoadResult:
	var data: Dictionary
	var errors: Array[String]
	var warnings: Array[String]
	var source: String
	var used_fallback: bool
	var promoted_temporary: bool
	var _loaded: bool


	func _init(
		loaded_data: Dictionary,
		load_errors: Array[String],
		load_warnings: Array[String],
		loaded_source: String,
		fallback_used: bool,
		temporary_promoted: bool,
		was_loaded: bool,
	) -> void:
		data = loaded_data.duplicate(true)
		errors = load_errors.duplicate()
		warnings = load_warnings.duplicate()
		source = loaded_source
		used_fallback = fallback_used
		promoted_temporary = temporary_promoted
		_loaded = was_loaded


	func is_success() -> bool:
		return _loaded and errors.is_empty()


class ValidationResult:
	var data: Dictionary
	var errors: Array[String]


	func _init(validated_data: Dictionary, validation_errors: Array[String]) -> void:
		data = validated_data.duplicate(true)
		errors = validation_errors.duplicate()


	func is_success() -> bool:
		return errors.is_empty()


func _init(save_root_path: String = DEFAULT_ROOT_PATH) -> void:
	root_path = save_root_path.trim_suffix("/")


func save(slot: int, state_data: Dictionary) -> SaveResult:
	var errors: Array[String] = _rotate_backups(slot)
	if not errors.is_empty():
		return SaveResult.new(errors)
	errors = _write_temporary(slot, state_data)
	if not errors.is_empty():
		return SaveResult.new(errors)
	errors = _replace_with_temporary(slot)
	return SaveResult.new(errors)


func load(slot: int) -> LoadResult:
	var path_error: String = _slot_error(slot)
	if not path_error.is_empty():
		return LoadResult.new({}, [path_error], [], "", false, false, false)

	var warnings: Array[String] = []
	var attempted_errors: Array[String] = []
	var temporary_path: String = _file_path(slot, "save.tmp.json")
	if FileAccess.file_exists(temporary_path):
		var temporary_result: ValidationResult = _validate_file(temporary_path)
		if temporary_result.is_success():
			var promotion_errors: Array[String] = _replace_with_temporary(slot)
			if not promotion_errors.is_empty():
				return LoadResult.new(
					{}, promotion_errors, warnings, "save.tmp.json", false, false, false
				)
			warnings.append("未昇格の一時セーブを検出したため save.json へ昇格しました。")
			return LoadResult.new(
				temporary_result.data, [], warnings, "save.tmp.json", false, true, true
			)
		var temporary_errors: Array[String] = _with_file_label(
			"save.tmp.json", temporary_result.errors
		)
		attempted_errors.append_array(temporary_errors)
		warnings.append_array(temporary_errors)
		warnings.append("破損した save.tmp.json を削除しました。")
		var remove_error: Error = DirAccess.remove_absolute(_absolute_path(temporary_path))
		if remove_error != OK:
			return LoadResult.new(
				{},
				["破損した save.tmp.json を削除できません: %s" % error_string(remove_error)],
				warnings,
				"",
				false,
				false,
				false,
			)

	var candidates: Array[String] = ["save.json", "save.bak1.json", "save.bak2.json"]
	for index: int in range(candidates.size()):
		var file_name: String = candidates[index]
		var candidate_path: String = _file_path(slot, file_name)
		if not FileAccess.file_exists(candidate_path):
			continue
		var result: ValidationResult = _validate_file(candidate_path)
		if result.is_success():
			var fallback_used: bool = index > 0
			if fallback_used:
				warnings.append("%s へフォールバックしてロードしました。" % file_name)
			return LoadResult.new(result.data, [], warnings, file_name, fallback_used, false, true)
		var candidate_errors: Array[String] = _with_file_label(file_name, result.errors)
		attempted_errors.append_array(candidate_errors)
		warnings.append_array(candidate_errors)
		warnings.append("%s の検証に失敗しました。" % file_name)

	if attempted_errors.is_empty():
		attempted_errors.append("スロット %d にロード可能なセーブデータがありません。" % slot)
	else:
		attempted_errors.append("すべてのセーブ世代が破損しているためロードできません。")
	return LoadResult.new({}, attempted_errors, warnings, "", false, false, false)


# 手順1: bak1 を bak2 へ rename してから、現行 save を bak1 へコピーする。
# save.json はコピー完了後も残るため、この手順の途中にも確定状態を失わない。
func _rotate_backups(slot: int) -> Array[String]:
	var errors: Array[String] = _prepare_slot(slot)
	if not errors.is_empty():
		return errors

	var backup_one_path: String = _file_path(slot, "save.bak1.json")
	var backup_two_path: String = _file_path(slot, "save.bak2.json")
	if FileAccess.file_exists(backup_one_path):
		var rename_error: Error = DirAccess.rename_absolute(
			_absolute_path(backup_one_path), _absolute_path(backup_two_path)
		)
		if rename_error != OK:
			return ["bak1 から bak2 へのローテーションに失敗しました: %s" % error_string(rename_error)]

	var save_path: String = _file_path(slot, "save.json")
	if FileAccess.file_exists(save_path):
		var copy_error: Error = DirAccess.copy_absolute(
			_absolute_path(save_path), _absolute_path(backup_one_path)
		)
		if copy_error != OK:
			return ["save.json から bak1 へのコピーに失敗しました: %s" % error_string(copy_error)]
	return []


# 手順2: 完成済みの文書を tmp に全書き込みし、FileAccess.flush() で永続化を要求する。
func _write_temporary(slot: int, state_data: Dictionary) -> Array[String]:
	var errors: Array[String] = _prepare_slot(slot)
	if not errors.is_empty():
		return errors

	var document_without_checksum: Dictionary = {
		"schema_version": CURRENT_SCHEMA_VERSION,
		"data": state_data.duplicate(true),
	}
	var checksum: String = _checksum(document_without_checksum)
	var document: Dictionary = {
		"schema_version": CURRENT_SCHEMA_VERSION,
		"checksum": checksum,
		"data": state_data.duplicate(true),
	}
	var temporary_path: String = _file_path(slot, "save.tmp.json")
	var file: FileAccess = FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return ["save.tmp.json を開けません: %s" % error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify(document, "\t", false, true) + "\n")
	file.flush()
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK:
		return ["save.tmp.json の書き込みに失敗しました: %s" % error_string(write_error)]
	return []


# 手順3: 同一ディレクトリ内の rename により tmp を save へ原子的に上書きする。
# save.json の delete は行わず、「save.json が存在しない瞬間」を作らない。
func _replace_with_temporary(slot: int) -> Array[String]:
	var path_error: String = _slot_error(slot)
	if not path_error.is_empty():
		return [path_error]
	var temporary_path: String = _file_path(slot, "save.tmp.json")
	if not FileAccess.file_exists(temporary_path):
		return ["置換元の save.tmp.json が存在しません。"]
	var rename_error: Error = DirAccess.rename_absolute(
		_absolute_path(temporary_path), _absolute_path(_file_path(slot, "save.json"))
	)
	if rename_error != OK:
		return ["save.tmp.json から save.json への原子的置換に失敗しました: %s" % error_string(rename_error)]
	return []


func _validate_file(path: String) -> ValidationResult:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ValidationResult.new({}, ["ファイルを開けません: %s" % error_string(FileAccess.get_open_error())])
	var text: String = file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK:
		return ValidationResult.new({}, ["ファイルの読み込みに失敗しました: %s" % error_string(read_error)])

	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(text)
	if parse_error != OK:
		return ValidationResult.new(
			{},
			["JSONの解析に失敗しました（行%d）: %s" % [json.get_error_line(), json.get_error_message()]],
		)
	if typeof(json.data) != TYPE_DICTIONARY:
		return ValidationResult.new({}, ["ルート: JSONオブジェクトである必要があります。"])

	var document: Dictionary = json.data
	var errors: Array[String] = []
	if not document.has("schema_version") or not _is_integer_value(document["schema_version"]):
		errors.append("schema_version: 整数の必須項目です。")
	else:
		var schema_version: int = int(document["schema_version"])
		if schema_version != CURRENT_SCHEMA_VERSION:
			errors.append("schema_version: 未知のバージョン %d です。" % schema_version)
	if not document.has("checksum") or typeof(document["checksum"]) != TYPE_STRING:
		errors.append("checksum: 文字列の必須項目です。")
	if not document.has("data") or typeof(document["data"]) != TYPE_DICTIONARY:
		errors.append("data: JSONオブジェクトの必須項目です。")
	if not errors.is_empty():
		return ValidationResult.new({}, errors)

	var checksum_source: Dictionary = document.duplicate(true)
	checksum_source.erase("checksum")
	var expected_checksum: String = _checksum(checksum_source)
	var actual_checksum: String = String(document["checksum"])
	if actual_checksum != expected_checksum:
		return ValidationResult.new({}, ["checksum: SHA-256 検証に失敗しました。"])

	return _migrate(document)


func _migrate(document: Dictionary) -> ValidationResult:
	var schema_version: int = int(document["schema_version"])
	if schema_version == CURRENT_SCHEMA_VERSION:
		var current_data: Dictionary = document["data"]
		return ValidationResult.new(current_data, [])

	# 将来は migrations/v{n}_to_v{n+1}.gd をここで順番に適用し、
	# 適用前文書を save.pre_migration.json として保持する。
	return ValidationResult.new({}, ["schema_version: 移行経路がないバージョン %d です。" % schema_version])


# 正規化規則: Dictionary のキーを全階層で昇順に並べ、Array の順序は保持する。
# JSON パーサーが整数を float で返すため、整数値の float は int 表現へ統一する。
# その値を空インデント・キーソート有効・完全精度で JSON 化し、SHA-256 を計算する。
func _checksum(value: Variant) -> String:
	var canonical_value: Variant = _canonicalize(value)
	var canonical_json: String = JSON.stringify(canonical_value, "", true, true)
	return canonical_json.sha256_text()


func _canonicalize(value: Variant) -> Variant:
	if typeof(value) == TYPE_DICTIONARY:
		var dictionary_value: Dictionary = value
		var keys: Array[String] = []
		for key_value: Variant in dictionary_value.keys():
			keys.append(String(key_value))
		keys.sort()
		var canonical_dictionary: Dictionary = {}
		for key: String in keys:
			canonical_dictionary[key] = _canonicalize(dictionary_value[key])
		return canonical_dictionary
	if typeof(value) == TYPE_ARRAY:
		var array_value: Array = value
		var canonical_array: Array = []
		for item: Variant in array_value:
			canonical_array.append(_canonicalize(item))
		return canonical_array
	if typeof(value) == TYPE_FLOAT:
		var float_value: float = value
		if is_finite(float_value) and float_value == floor(float_value):
			return int(float_value)
	return value


func _prepare_slot(slot: int) -> Array[String]:
	var path_error: String = _slot_error(slot)
	if not path_error.is_empty():
		return [path_error]
	var make_error: Error = DirAccess.make_dir_recursive_absolute(
		_absolute_path(_slot_path(slot))
	)
	if make_error != OK:
		return ["セーブディレクトリを作成できません: %s" % error_string(make_error)]
	return []


func _slot_error(slot: int) -> String:
	if slot < 0:
		return "セーブスロット番号は0以上である必要があります。"
	return ""


func _slot_path(slot: int) -> String:
	return root_path.path_join("slot_%d" % slot)


func _file_path(slot: int, file_name: String) -> String:
	return _slot_path(slot).path_join(file_name)


func _absolute_path(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _with_file_label(file_name: String, errors: Array[String]) -> Array[String]:
	var labeled: Array[String] = []
	for error_message: String in errors:
		labeled.append("%s: %s" % [file_name, error_message])
	return labeled


func _is_integer_value(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var float_value: float = value
	return is_finite(float_value) and float_value == floor(float_value)
