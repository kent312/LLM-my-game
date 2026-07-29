class_name ExternalConnectionIndicator
extends Label


func apply_settings(settings: Dictionary) -> void:
	var mode: String = String(
		settings.get("connection_mode", ExternalSettingsStore.MODE_BUNDLED)
	)
	visible = ExternalSettingsStore.is_external_active(settings)
	if not visible:
		text = ""
		return
	var destination_type: String = tr("クラウドAPI")
	if mode == ExternalSettingsStore.MODE_EXTERNAL_LOCAL:
		destination_type = tr("外部ローカルLLM")
	text = tr("外部AI接続中") + "｜" + destination_type
	add_theme_color_override("font_color", Color("#f2cf77"))


func apply_fallback_state(using_fallback: bool, settings: Dictionary) -> void:
	if not using_fallback:
		apply_settings(settings)
		return
	visible = true
	text = tr("同梱モデルへ一時切替中")
	add_theme_color_override("font_color", Color("#8fc6b2"))
