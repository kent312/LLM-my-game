class_name ExternalSettingsDialog
extends Window

signal settings_saved(settings: Dictionary)

var store: ExternalSettingsStore

var _mode_option: OptionButton
var _endpoint_line: LineEdit
var _api_key_line: LineEdit
var _model_line: LineEdit
var _consent_check: CheckBox
var _consent_label: Label
var _capability_label: Label
var _error_label: Label
var _save_button: Button


func _init(settings_store: ExternalSettingsStore = null) -> void:
	store = settings_store if settings_store != null else ExternalSettingsStore.new()


func _ready() -> void:
	title = tr("外部AI接続設定")
	size = Vector2i(720, 650)
	exclusive = true
	close_requested.connect(hide)
	_build_interface()
	_load_current_settings()


func consent_notice(endpoint: String) -> String:
	var destination: String = endpoint.strip_edges()
	if destination.is_empty():
		destination = tr("（送信先を入力してください）")
	return (
		tr("外部AIへ送信されるデータ")
		+ "\n"
		+ tr("・システムプロンプト")
		+ "\n"
		+ tr("・キャラシート要約")
		+ "\n"
		+ tr("・現在シーン情報")
		+ "\n"
		+ tr("・会話履歴または要約")
		+ "\n"
		+ tr("・プレイヤー入力")
		+ "\n\n"
		+ tr("送信先: %s") % destination
		+ "\n"
		+ tr("送信先での保存・利用・その他の挙動は、このゲームの管理外です。")
		+ "\n"
		+ tr("外部サービスの利用規約と年齢制限に従ってください。")
		+ "\n\n"
		+ tr("APIキーはOS資格情報ストアではなく settings.json に平文で保存されます。")
		+ "\n"
		+ tr("APIキーはセーブデータやエクスポートデータには含まれません。")
	)


func show_constrained_output_warning() -> void:
	if _capability_label == null:
		return
	_capability_label.text = tr(
		"このエンドポイントは構造化出力に非対応です。分類が不安定になる可能性があります。"
	)
	_capability_label.visible = true


func _build_interface() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var heading: Label = Label.new()
	heading.text = tr("外部AI接続設定")
	heading.add_theme_font_size_override("font_size", 24)
	column.add_child(heading)

	_mode_option = OptionButton.new()
	_mode_option.add_item(tr("同梱モデル（完全オフライン）"))
	_mode_option.set_item_metadata(0, ExternalSettingsStore.MODE_BUNDLED)
	_mode_option.add_item(tr("外部ローカルLLM"))
	_mode_option.set_item_metadata(1, ExternalSettingsStore.MODE_EXTERNAL_LOCAL)
	_mode_option.add_item(tr("クラウドAPI"))
	_mode_option.set_item_metadata(2, ExternalSettingsStore.MODE_CLOUD_API)
	_mode_option.item_selected.connect(_on_mode_selected)
	column.add_child(_labeled_control(tr("接続モード"), _mode_option))

	_endpoint_line = LineEdit.new()
	_endpoint_line.placeholder_text = tr("例: http://127.0.0.1:11434")
	_endpoint_line.text_changed.connect(_on_endpoint_changed)
	column.add_child(_labeled_control(tr("送信先エンドポイント"), _endpoint_line))

	_api_key_line = LineEdit.new()
	_api_key_line.secret = true
	_api_key_line.placeholder_text = tr("クラウドAPIで使用するキー")
	column.add_child(_labeled_control(tr("APIキー"), _api_key_line))

	_model_line = LineEdit.new()
	_model_line.placeholder_text = tr("送信先で利用するモデル名")
	column.add_child(_labeled_control(tr("モデル"), _model_line))

	_consent_label = Label.new()
	_consent_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_consent_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_consent_label)

	_consent_check = CheckBox.new()
	_consent_check.text = tr("上記の送信内容・送信先・管理範囲外の挙動・外部規約に明示同意します")
	_consent_check.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_consent_check)

	_capability_label = Label.new()
	_capability_label.visible = false
	_capability_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_capability_label.add_theme_color_override("font_color", Color("#f2cf77"))
	column.add_child(_capability_label)

	_error_label = Label.new()
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.add_theme_color_override("font_color", Color("#e58b8b"))
	column.add_child(_error_label)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(buttons)
	var cancel_button: Button = Button.new()
	cancel_button.text = tr("キャンセル")
	cancel_button.pressed.connect(hide)
	buttons.add_child(cancel_button)
	_save_button = Button.new()
	_save_button.text = tr("設定を保存")
	_save_button.pressed.connect(_on_save_pressed)
	buttons.add_child(_save_button)
	_refresh_notice_and_fields()


func _labeled_control(label_text: String, control: Control) -> VBoxContainer:
	var container: VBoxContainer = VBoxContainer.new()
	var label: Label = Label.new()
	label.text = label_text
	container.add_child(label)
	container.add_child(control)
	return container


func _load_current_settings() -> void:
	var result: ExternalSettingsStore.LoadResult = store.load_settings()
	var settings: Dictionary[String, Variant] = result.settings
	if not result.is_success():
		_error_label.text = "\n".join(result.errors)
	var mode: String = String(settings["connection_mode"])
	for index: int in range(_mode_option.item_count):
		if String(_mode_option.get_item_metadata(index)) == mode:
			_mode_option.select(index)
			break
	_endpoint_line.text = String(settings["endpoint"])
	_api_key_line.text = String(settings["api_key"])
	_model_line.text = String(settings["model"])
	_consent_check.button_pressed = bool(settings["privacy_consent"])
	_refresh_notice_and_fields()


func _on_mode_selected(_index: int) -> void:
	_consent_check.button_pressed = false
	_refresh_notice_and_fields()


func _on_endpoint_changed(_new_text: String) -> void:
	# 同意後の送信先すり替えを防ぐため、アドレス変更時は再同意を要求する。
	_consent_check.button_pressed = false
	_refresh_notice_and_fields()


func _refresh_notice_and_fields() -> void:
	if _mode_option == null:
		return
	var external: bool = _selected_mode() != ExternalSettingsStore.MODE_BUNDLED
	_endpoint_line.editable = external
	_api_key_line.editable = external
	_model_line.editable = external
	_consent_check.visible = external
	_consent_label.visible = external
	_consent_label.text = consent_notice(_endpoint_line.text)


func _selected_mode() -> String:
	return String(_mode_option.get_item_metadata(_mode_option.selected))


func _on_save_pressed() -> void:
	var mode: String = _selected_mode()
	var candidate: Dictionary[String, Variant] = {
		"connection_mode": mode,
		"external_enabled": mode != ExternalSettingsStore.MODE_BUNDLED,
		"endpoint": _endpoint_line.text,
		"api_key": _api_key_line.text,
		"model": _model_line.text,
		"privacy_consent": _consent_check.button_pressed,
	}
	var result: ExternalSettingsStore.SaveResult = store.save_settings(candidate)
	if not result.is_success():
		_error_label.text = "\n".join(result.errors)
		return
	var loaded: ExternalSettingsStore.LoadResult = store.load_settings()
	if not loaded.is_success():
		_error_label.text = "\n".join(loaded.errors)
		return
	_error_label.text = ""
	settings_saved.emit(loaded.settings)
	hide()
