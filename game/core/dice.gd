class_name Dice

static func roll(
	mode: Types.RollMode,
	rng: RandomNumberGenerator,
) -> Dictionary[String, Variant]:
	var dice_count: int = 2 if mode == Types.RollMode.NORMAL else 3
	var dice: Array[int] = []
	for _roll_index: int in range(dice_count):
		dice.append(rng.randi_range(1, 6))

	var kept: Array[int] = dice.duplicate()
	if mode != Types.RollMode.NORMAL:
		kept.sort()
		if mode == Types.RollMode.ADVANTAGE:
			kept.reverse()
		kept.resize(2)

	var natural: int = kept[0] + kept[1]
	return {
		"dice": dice,
		"kept": kept,
		"natural": natural,
	}
