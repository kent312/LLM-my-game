class_name PreviewBackendFactory
extends RefCounted

# PR-13でbackend_localへ差し替えるまで、最小UIを通し操作するための
# 暫定プレビュー用ファクトリ。出荷用AIバックエンドとしては使用しない。
const SCRIPT_PATH_FORMAT: String = (
	"res://game/data/scenarios/%s/preview_script.json"
)


static func create_for_state(state: GameState) -> LLMBackend:
	var backend: BackendMock = BackendMock.new()
	backend.delay_ms = 12
	backend.token_size = 3
	var script_path: String = SCRIPT_PATH_FORMAT % state.scenario_id
	backend.set_responses(_remaining_responses(state, _load_turns(script_path)))
	return backend


static func _remaining_responses(
	state: GameState,
	turns: Array[Dictionary],
) -> Array[String]:
	var responses: Array[String] = []
	if turns.is_empty():
		return responses
	var next_turn_index: int = clampi(state.turn_count, 0, turns.size())
	if typeof(state.pending_narration) == TYPE_DICTIONARY and state.turn_count > 0:
		var pending_turn_index: int = clampi(state.turn_count - 1, 0, turns.size() - 1)
		responses.append(String(turns[pending_turn_index].get("narration", "")))
	for index: int in range(next_turn_index, turns.size()):
		responses.append(JSON.stringify(turns[index].get("intent", {})))
		responses.append(String(turns[index].get("narration", "")))
	return responses


static func _load_turns(script_path: String) -> Array[Dictionary]:
	var turns: Array[Dictionary] = []
	var file: FileAccess = FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return turns
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return turns
	var root: Dictionary = parsed
	var turns_value: Variant = root.get("turns", [])
	if typeof(turns_value) != TYPE_ARRAY:
		return turns
	var raw_turns: Array = turns_value
	for turn_value: Variant in raw_turns:
		if typeof(turn_value) == TYPE_DICTIONARY:
			var turn: Dictionary = turn_value
			turns.append(turn.duplicate(true))
	return turns
