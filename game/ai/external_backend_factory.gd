class_name ExternalBackendFactory
extends RefCounted


static func create_for_state(
	settings: Dictionary,
	state: GameState,
	request_sender: Callable = Callable(),
) -> LLMBackend:
	if not ExternalSettingsStore.is_external_active(settings):
		# INV-4: 未設定・未同意・同梱モードではHTTP機能を持つインスタンスすら生成しない。
		return PreviewBackendFactory.create_for_state(state)
	var backend: BackendOpenAI = BackendOpenAI.new(
		String(settings.get("endpoint", "")),
		String(settings.get("api_key", "")),
		String(settings.get("model", "")),
		request_sender,
	)
	# PR-13でbackend_localへ差し替えるまでの暫定切替先。
	backend.set_fallback_backend(PreviewBackendFactory.create_for_state(state))
	return backend
