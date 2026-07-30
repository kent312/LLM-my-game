class_name DataLookup


static func find_by_field(
	values_value: Variant,
	field: String,
	expected: String,
) -> Dictionary:
	if typeof(values_value) != TYPE_ARRAY:
		return {}
	var values: Array = values_value
	for value: Variant in values:
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = value
		if String(entry.get(field, "")) == expected:
			return entry
	return {}
