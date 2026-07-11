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

	assert_eq(dice.size(), 3)
	assert_eq(kept, _expected_kept(dice, true))


func test_disadvantage_keeps_lowest_two_of_three() -> void:
	var result: Dictionary[String, Variant] = Dice.roll(Types.RollMode.DISADVANTAGE, _rng)
	var dice: Array[int] = result["dice"]
	var kept: Array[int] = result["kept"]

	assert_eq(dice.size(), 3)
	assert_eq(kept, _expected_kept(dice, false))


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


func _expected_kept(dice: Array[int], keep_highest: bool) -> Array[int]:
	var expected: Array[int] = dice.duplicate()
	expected.sort()
	if keep_highest:
		expected.reverse()
	expected.resize(2)
	return expected


func _assert_natural_range_for_ten_thousand_rolls(mode: Types.RollMode) -> void:
	for _roll_index: int in range(10_000):
		var result: Dictionary[String, Variant] = Dice.roll(mode, _rng)
		var natural: int = result["natural"]
		if natural < 2 or natural > 12:
			fail_test("RollMode %d の natural が範囲外です: %d" % [mode, natural])
			return

	pass_test("RollMode %d の natural は10000回すべて 2..12 に収まりました" % mode)
