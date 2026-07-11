class_name Types

enum Ability { STR, DEX, CON, INT, WIS, CHA }

enum ResultTier { FUMBLE, FAILURE, PARTIAL, SUCCESS, CRITICAL }

enum Difficulty { EASY, NORMAL, HARD }

enum RollMode { NORMAL, ADVANTAGE, DISADVANTAGE }

const THRESHOLD_SUCCESS: int = 10
const THRESHOLD_PARTIAL: int = 7
const SKILL_BONUS: int = 1
const ABILITY_MIN: int = -1
const ABILITY_MAX: int = 3
