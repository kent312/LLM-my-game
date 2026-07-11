extends GutTest

const TEST_SEED: int = 0x5EED

var _rng: RandomNumberGenerator


func before_each() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = TEST_SEED


func test_normal_rolls_two_dice() -> void:
	var result: Dictionary[String, Variant] = Dice.roll(Types.RollMode.NORMAL, _rng)
	var dice: Array[int] = result["dice"]

	assert_eq(dice.size(), 2)


func test_advantage_keeps_highest_two_of_three() -> void:
	var result: Dictionary[String, Variant] = Dice.roll(Types.RollMode.ADVANTAGE, _rng)
	var dice: Array[int] = result["dice"]
	var kept: Array[int] = result["kept"]
	var expected_kept: Array[int] = dice.duplicate()
	expected_kept.sort()
	expected_kept.reverse()
	expected_kept.resize(2)

	assert_eq(dice.size(), 3)
	assert_eq(kept, expected_kept)


func test_disadvantage_keeps_lowest_two_of_three() -> void:
	var result: Dictionary[String, Variant] = Dice.roll(Types.RollMode.DISADVANTAGE, _rng)
	var dice: Array[int] = result["dice"]
	var kept: Array[int] = result["kept"]
	var expected_kept: Array[int] = dice.duplicate()
	expected_kept.sort()
	expected_kept.resize(2)

	assert_eq(dice.size(), 3)
	assert_eq(kept, expected_kept)


func test_natural_equals_sum_of_kept_dice() -> void:
	_assert_natural_equals_kept_sum(Types.RollMode.NORMAL)
	_assert_natural_equals_kept_sum(Types.RollMode.ADVANTAGE)
	_assert_natural_equals_kept_sum(Types.RollMode.DISADVANTAGE)


func test_natural_stays_between_two_and_twelve_for_ten_thousand_rolls() -> void:
	_assert_natural_range_for_ten_thousand_rolls(Types.RollMode.NORMAL)
	_assert_natural_range_for_ten_thousand_rolls(Types.RollMode.ADVANTAGE)
	_assert_natural_range_for_ten_thousand_rolls(Types.RollMode.DISADVANTAGE)


func _assert_natural_equals_kept_sum(mode: Types.RollMode) -> void:
	var result: Dictionary[String, Variant] = Dice.roll(mode, _rng)
	var kept: Array[int] = result["kept"]
	var natural: int = result["natural"]

	assert_eq(natural, kept[0] + kept[1])


func _assert_natural_range_for_ten_thousand_rolls(mode: Types.RollMode) -> void:
	var all_rolls_in_range: bool = true
	var first_out_of_range: int = 0
	for _roll_index: int in range(10_000):
		var result: Dictionary[String, Variant] = Dice.roll(mode, _rng)
		var natural: int = result["natural"]
		if natural < 2 or natural > 12:
			all_rolls_in_range = false
			first_out_of_range = natural
			break

	assert_true(
		all_rolls_in_range,
		"RollMode %d の natural が範囲外です: %d" % [mode, first_out_of_range],
	)
