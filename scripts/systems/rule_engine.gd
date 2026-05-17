extends RefCounted
class_name RuleEngine

# 功能：将属性值裁剪到 [min_value, max_value] 区间。
static func clamp_attribute(value: int, min_value: int = 1, max_value: int = 999999) -> int:
	return clampi(value, min_value, max_value)

# 功能：根据属性当前值和阈值数组，返回阶段值（0 / 1 / 2 / 3...）。
# 说明：thresholds 为升序阈值数组，例如 [0, 3, 7, 12]。
static func get_ability_stage(value: int, thresholds: Array) -> int:
	var stage := 0
	for i in thresholds.size():
		if value >= int(thresholds[i]):
			stage = i
		else:
			break
	return stage

# 功能：从 RoleState 读取指定字段值，调用 get_ability_stage 返回阶段值。
# 说明：RoleState 是运行时权威数据源。
static func get_stage_from_role(role_state: Variant, key: String, thresholds: Array) -> int:
	var value := int(role_state.get_value(key, 0))
	return get_ability_stage(value, thresholds)

# 功能：执行鉴定聚合计算，遍历 items 累加正向阶段、累减负向阶段，返回综合得分。
# items 格式：[{"key": "physique", "direction": "positive"}, ...]
static func evaluate_assessment(items: Array, role_state: Variant, thresholds: Array) -> int:
	var score := 0
	for item_variant in items:
		var item: Dictionary = item_variant
		var key := str(item.get("key", ""))
		var direction := str(item.get("direction", "positive"))
		var stage := get_stage_from_role(role_state, key, thresholds)
		if direction == "negative":
			score -= stage
		else:
			score += stage
	return score

# 功能：应用资源增减。
# 说明：按设计资源允许为负数。
static func apply_resource_delta(current_value: int, delta: int) -> int:
	return current_value + delta

# 功能：将好感度分值映射为五档档位标签。
# 说明：五档依次为 hatred / distrust / neutral / trust / devotion。
#       阈值从 thresholds 字典读取，缺省使用默认值。
static func affinity_tier(score: int, thresholds: Dictionary = {}) -> String:
	var hatred_max := int(thresholds.get("tier_hatred_max", -51))
	var distrust_max := int(thresholds.get("tier_distrust_max", -11))
	var trust_min := int(thresholds.get("tier_trust_min", 11))
	var devotion_min := int(thresholds.get("tier_devotion_min", 51))
	if score <= hatred_max:
		return "hatred"
	if score <= distrust_max:
		return "distrust"
	if score >= devotion_min:
		return "devotion"
	if score >= trust_min:
		return "trust"
	return "neutral"

# 功能：统一检定判定入口。
# 说明：接收 check 配置、角色状态、风险修正器，返回判定结果。
# 支持返回四类 result_type：critical_success / success / fail / critical_fail。
static func resolve_check(
	check: Dictionary,
	role_state: Variant,
	thresholds: Array = [],
	rng: Variant = null,
	risk_modifiers: Dictionary = {}
) -> Dictionary:
	if check.is_empty():
		return {"pass": true, "result_type": "success", "risk_modifiers": risk_modifiers}
	var check_type := str(check.get("type", "")).strip_edges()
	if check_type == "chance":
		var base_pass_rate := clampf(float(check.get("successRate", 1.0)), 0.0, 1.0)
		var probs := _build_chance_probabilities(base_pass_rate)
		probs = _apply_probability_biases(probs, risk_modifiers)
		probs = _apply_risk_profile_constraints(probs, risk_modifiers)
		var result_type := _roll_result_type(probs, rng)
		return {
			"pass": _is_pass_result(result_type),
			"result_type": result_type,
			"probabilities": probs,
			"risk_modifiers": risk_modifiers
		}
	if check_type == "assessment":
		var hit_threshold := int(check.get("hitThreshold", 6))
		var required_hits := int(check.get("requiredHits", 1))
		var items: Array = check.get("items", [])
		var score := 0
		if role_state != null and typeof(role_state) != TYPE_DICTIONARY and role_state.has_method("get_value"):
			score = evaluate_assessment(items, role_state, thresholds)
		else:
			# JSON 路径回退：从 Dictionary 手动计算评分。
			for item_variant in items:
				var item: Dictionary = item_variant
				var key := str(item.get("key", ""))
				var direction := str(item.get("direction", "positive"))
				var value := 0
				if typeof(role_state) == TYPE_DICTIONARY and role_state != null:
					value = int(role_state.get(key, 0))
				var stage := get_ability_stage(value, thresholds)
				if direction == "negative":
					score -= stage
				else:
					score += stage
		# 骰池机制：score 决定骰子数，偏置加减骰子，心性额外加骰。
		var bonus_dice := _calc_bonus_dice(risk_modifiers)
		var pool_size := maxi(1, score + bonus_dice)
		var dice := _roll_dice_pool(pool_size, rng)
		var raw_result := _evaluate_dice_pool(dice, hit_threshold, required_hits)
		var result_type := _apply_xinxing_constraint(raw_result, risk_modifiers)
		var hits := _count_hits(dice, hit_threshold)
		return {
			"pass": _is_pass_result(result_type),
			"result_type": result_type,
			"score": score,
			"pool_size": pool_size,
			"dice": dice,
			"hits": hits,
			"hitThreshold": hit_threshold,
			"requiredHits": required_hits,
			"risk_modifiers": risk_modifiers
		}
	# 未知类型默认通过
	return {"pass": true, "result_type": "success", "risk_modifiers": risk_modifiers}

# 功能：构建 chance 检定的基础概率分布。
# 说明：以 successRate 作为通过率，再切分 critical 子区间。
static func _build_chance_probabilities(pass_rate: float) -> Dictionary:
	var p := clampf(pass_rate, 0.0, 1.0)
	var critical_success := clampf(p * 0.25, 0.0, 0.25)
	var critical_fail := clampf((1.0 - p) * 0.25, 0.0, 0.25)
	return _normalize_probabilities(
		{
			"critical_success": critical_success,
			"success": maxf(0.0, p - critical_success),
			"fail": maxf(0.0, (1.0 - p) - critical_fail),
			"critical_fail": critical_fail
		}
	)

# 功能：掷骰池，返回每颗 d10 的骰面数组。
# 说明：pool_size 颗 d10，每颗结果范围 1~10。
static func _roll_dice_pool(pool_size: int, rng: Variant = null) -> Array:
	var dice: Array = []
	for i in pool_size:
		var roll: int
		if rng != null and rng.has_method("randi_range"):
			roll = rng.randi_range(1, 10)
		elif rng != null and rng.has_method("randf"):
			# 兼容只有 randf 的 MockRng：将 0~1 映射到 1~10。
			roll = int(rng.randf() * 10.0) + 1
			roll = clampi(roll, 1, 10)
		else:
			roll = randi_range(1, 10)
		dice.append(roll)
	return dice

# 功能：统计骰池中命中数。
static func _count_hits(dice: Array, hit_threshold: int) -> int:
	var hits := 0
	for die in dice:
		if int(die) >= hit_threshold:
			hits += 1
	return hits

# 功能：根据骰池结果判定四档 result_type。
# 说明：通过=命中数≥需要数；大成功=通过且有10；大失败=失败且有1。
static func _evaluate_dice_pool(dice: Array, hit_threshold: int, required_hits: int) -> String:
	var hits := _count_hits(dice, hit_threshold)
	var has_ten := false
	var has_one := false
	for die in dice:
		if int(die) == 10:
			has_ten = true
		if int(die) == 1:
			has_one = true
	if hits >= required_hits:
		if has_ten:
			return "critical_success"
		return "success"
	else:
		if has_one:
			return "critical_fail"
		return "fail"

# 功能：计算偏置带来的额外骰子数。
# 说明：successBias + stability_bias + relationship_bias 合并为加减骰子数（正数加骰，负数减骰）。
static func _calc_bonus_dice(risk_modifiers: Dictionary) -> int:
	return int(risk_modifiers.get("successBias", 0)) \
		 + int(risk_modifiers.get("stability_bias", 0)) \
		 + int(risk_modifiers.get("relationship_bias", 0))

# 功能：根据心性阶段对骰池 result_type 做门控约束。
# 说明：与 chance 检定的 _apply_risk_profile_constraints 逻辑对应，但直接操作 result_type 字符串。
static func _apply_xinxing_constraint(result_type: String, risk_modifiers: Dictionary) -> String:
	var xinxing := int(risk_modifiers.get("xinxing", 0))
	if xinxing < -2 or xinxing > 2:
		xinxing = 0
	# 0 / -1 / -2 不允许大成功 → 降级为 success。
	if xinxing <= 0 and result_type == "critical_success":
		return "success"
	# +1 / +2 / 0 不允许大失败 → 降级为 fail。
	if xinxing >= 0 and result_type == "critical_fail":
		return "fail"
	# -2 阶段所有失败强制升级为大失败。
	if xinxing == -2 and result_type == "fail":
		return "critical_fail"
	return result_type

# 功能：应用主动押注与稳定倾向等偏置参数。
# 说明：successBias / criticalSuccessBias / criticalFailBias 使用“百分点”语义（1=1%）。
static func _apply_probability_biases(base_probs: Dictionary, risk_modifiers: Dictionary) -> Dictionary:
	var probs := _normalize_probabilities(base_probs)
	var success_bias_total := int(risk_modifiers.get("successBias", 0)) + int(risk_modifiers.get("stability_bias", 0))
	var cs_bias := int(risk_modifiers.get("criticalSuccessBias", 0))
	var cf_bias := int(risk_modifiers.get("criticalFailBias", 0))
	_apply_delta_pair(probs, "success", "fail", float(success_bias_total) / 100.0)
	_apply_delta_pair(probs, "critical_success", "success", float(cs_bias) / 100.0)
	_apply_delta_pair(probs, "critical_fail", "fail", float(cf_bias) / 100.0)
	return _normalize_probabilities(probs)

# 功能：根据心性阶段约束 critical 结果是否允许出现。
# 说明：对不允许出现的 result_type 做重映射；-2 阶段失败必然映射到 critical_fail。
static func _apply_risk_profile_constraints(base_probs: Dictionary, risk_modifiers: Dictionary) -> Dictionary:
	var probs := _normalize_probabilities(base_probs)
	var xinxing := int(risk_modifiers.get("xinxing", 0))
	if xinxing < -2 or xinxing > 2:
		xinxing = 0

	# +2 阶段可出现大成功且更强：概率上给予额外倾斜。
	if xinxing == 2:
		_apply_delta_pair(probs, "critical_success", "success", 0.05)

	# 0 / -1 / -2 不允许大成功。
	if xinxing <= 0:
		probs["success"] = float(probs.get("success", 0.0)) + float(probs.get("critical_success", 0.0))
		probs["critical_success"] = 0.0

	# +1 / +2 / 0 不允许大失败。
	if xinxing >= 0:
		probs["fail"] = float(probs.get("fail", 0.0)) + float(probs.get("critical_fail", 0.0))
		probs["critical_fail"] = 0.0

	# -2 阶段失败必然大失败。
	if xinxing == -2:
		probs["critical_fail"] = float(probs.get("critical_fail", 0.0)) + float(probs.get("fail", 0.0))
		probs["fail"] = 0.0

	return _normalize_probabilities(probs)

# 功能：在 from_key 与 to_key 之间转移概率增量。
# 说明：delta > 0 从 to_key 向 from_key 挪动；delta < 0 则反向挪动。
static func _apply_delta_pair(probs: Dictionary, from_key: String, to_key: String, delta: float) -> void:
	if is_zero_approx(delta):
		return
	var from_value := float(probs.get(from_key, 0.0))
	var to_value := float(probs.get(to_key, 0.0))
	if delta > 0.0:
		var actual := minf(delta, to_value)
		from_value += actual
		to_value -= actual
	else:
		var reverse := minf(-delta, from_value)
		from_value -= reverse
		to_value += reverse
	probs[from_key] = maxf(0.0, from_value)
	probs[to_key] = maxf(0.0, to_value)

# 功能：标准化四结果概率，保证总和为 1。
static func _normalize_probabilities(probs: Dictionary) -> Dictionary:
	var cs := maxf(0.0, float(probs.get("critical_success", 0.0)))
	var s := maxf(0.0, float(probs.get("success", 0.0)))
	var f := maxf(0.0, float(probs.get("fail", 0.0)))
	var cf := maxf(0.0, float(probs.get("critical_fail", 0.0)))
	var sum := cs + s + f + cf
	if sum <= 0.000001:
		return {"critical_success": 0.0, "success": 1.0, "fail": 0.0, "critical_fail": 0.0}
	return {
		"critical_success": cs / sum,
		"success": s / sum,
		"fail": f / sum,
		"critical_fail": cf / sum
	}

# 功能：按概率分布采样结果类型。
# 说明：累计区间顺序固定为 critical_success → success → fail → critical_fail。
static func _roll_result_type(probs: Dictionary, rng: Variant = null) -> String:
	var roll := randf()
	if rng != null and rng.has_method("randf"):
		roll = rng.randf()
	var cs := float(probs.get("critical_success", 0.0))
	var s := float(probs.get("success", 0.0))
	var f := float(probs.get("fail", 0.0))
	if roll < cs:
		return "critical_success"
	if roll < cs + s:
		return "success"
	if roll < cs + s + f:
		return "fail"
	return "critical_fail"

# 功能：判断结果是否属于通过态。
static func _is_pass_result(result_type: String) -> bool:
	return result_type == "success" or result_type == "critical_success"

# 功能：执行心性偏移并裁剪至 [-2, +2] 区间。
static func apply_xinxing_delta(current: int, delta: int) -> int:
	return clampi(current + delta, -2, 2)

# 功能：根据心性值返回风险入口配置。
# 说明：决定当前心性阶段下可用的风险机制（孤注一掷/主动押注）与稳定收益偏置。
static func get_xinxing_risk_profile(xinxing: int) -> Dictionary:
	match xinxing:
		-2:
			return {"allow_desperate_gamble": false, "allow_preemptive_bet": true, "stability_bias": 0}
		-1:
			return {"allow_desperate_gamble": true, "allow_preemptive_bet": false, "stability_bias": 0}
		0:
			return {"allow_desperate_gamble": true, "allow_preemptive_bet": false, "stability_bias": 0}
		1:
			return {"allow_desperate_gamble": true, "allow_preemptive_bet": false, "stability_bias": 0}
		2:
			return {"allow_desperate_gamble": true, "allow_preemptive_bet": false, "stability_bias": 1}
		_:
			return {"allow_desperate_gamble": true, "allow_preemptive_bet": false, "stability_bias": 0}

# 功能：应用好感度变化，并裁剪到 [-100, 100] 后返回分值与档位。
static func apply_affinity_delta(current_score: int, delta: int, thresholds: Dictionary = {}) -> Dictionary:
	var next_score := clampi(current_score + delta, -100, 100)
	return {
		"score": next_score,
		"tier": affinity_tier(next_score, thresholds)
	}

# 功能：执行单个 NPC 的关系修正判定，返回 bias 和掷骰详情。
# 说明：NPC→玩家档位决定判定次数与方向；玩家→NPC态度对齐修正命中值；掷 1d10 判定。
# 参数：
#   npc_to_player_score: NPC 对玩家的好感分值
#   player_to_npc_score: 玩家对 NPC 的好感分值
#   difficulty: 该 NPC 独立配置的关系鉴定难度
#   affinity_thresholds: 五档阈值字典
#   rng: 可选随机源，null 时使用全局随机
# 返回：{ bias, rolls, npc_tier, player_tier, direction, aligned }
static func resolve_relationship_check(
	npc_to_player_score: int,
	player_to_npc_score: int,
	difficulty: int,
	affinity_thresholds: Dictionary,
	rng: Variant = null
) -> Dictionary:
	var npc_tier := affinity_tier(npc_to_player_score, affinity_thresholds)
	var player_tier := affinity_tier(player_to_npc_score, affinity_thresholds)

	# NPC→玩家档位决定判定次数和方向
	var roll_count := 0
	var direction := "none"
	match npc_tier:
		"hatred":
			roll_count = 2
			direction = "remove"
		"distrust":
			roll_count = 1
			direction = "remove"
		"neutral":
			roll_count = 0
			direction = "none"
		"trust":
			roll_count = 1
			direction = "add"
		"devotion":
			roll_count = 2
			direction = "add"

	# neutral 不介入，直接返回
	if roll_count == 0:
		return {
			"bias": 0,
			"rolls": [],
			"npc_tier": npc_tier,
			"player_tier": player_tier,
			"direction": direction,
			"aligned": false
		}

	# 计算玩家态度对齐修正
	var alignment_bonus := _calc_alignment_bonus(player_tier, direction)
	var aligned := alignment_bonus != 0

	# 逐次掷骰判定
	var rolls: Array = []
	var bias := 0
	for i in roll_count:
		# 基础命中值 5，减去难度，加对齐修正，裁剪到 [0, 10]
		var hit_value := clampi(5 - difficulty + alignment_bonus, 0, 10)
		var die: int
		if rng != null and rng.has_method("randi_range"):
			die = rng.randi_range(1, 10)
		else:
			die = randi_range(1, 10)
		var success := die <= hit_value
		rolls.append({"die": die, "hit_value": hit_value, "success": success})
		if success:
			if direction == "add":
				bias += 1
			else:
				bias -= 1

	return {
		"bias": bias,
		"rolls": rolls,
		"npc_tier": npc_tier,
		"player_tier": player_tier,
		"direction": direction,
		"aligned": aligned
	}

# 功能：计算玩家态度对齐修正值。
# 说明：仅当玩家态度方向与 NPC 判定方向一致时生效，否则返回 0。
static func _calc_alignment_bonus(player_tier: String, npc_direction: String) -> int:
	if npc_direction == "add":
		# NPC 在帮助方向，玩家也偏信赖侧才对齐
		match player_tier:
			"devotion":
				return 2
			"trust":
				return 1
	elif npc_direction == "remove":
		# NPC 在阻挠方向，玩家也偏警戒侧才对齐
		match player_tier:
			"hatred":
				return -2
			"distrust":
				return -1
	return 0

# 功能：检查移动是否合法。
# 说明：支持 LocationGraph 对象或原始 Dictionary 两种输入。
static func can_move(location_graph: Variant, from_location_id: String, to_location_id: String) -> bool:
	if from_location_id == to_location_id:
		return true
	if location_graph == null:
		return false
	if location_graph.has_method("is_neighbor"):
		return location_graph.is_neighbor(from_location_id, to_location_id)
	if typeof(location_graph) == TYPE_DICTIONARY:
		var neighbors: Array = location_graph.get(from_location_id, [])
		return to_location_id in neighbors
	return false

# 功能：统一应用角色变化入口。
# 说明：1) 属性按最小值 1 与配置最大值裁剪。
#       2) 资源直接执行加减（允许负数）。
static func apply_role_delta(
	role_state: Variant,
	attribute_deltas: Dictionary,
	resource_deltas: Dictionary,
	attribute_max: Dictionary
) -> Dictionary:
	if role_state == null:
		return {"ok": false, "error": "role_state is null"}
	if not role_state.has_method("get_attribute"):
		return {"ok": false, "error": "role_state does not provide get_attribute"}

	for key in attribute_deltas.keys():
		var attr_key := str(key)
		var current := int(role_state.get_attribute(attr_key, 1))
		var delta := int(attribute_deltas[key])
		var max_value := int(attribute_max.get(attr_key, 99))
		var next_value := clamp_attribute(current + delta, 1, max_value)
		role_state.set_attribute(attr_key, next_value)

	for key in resource_deltas.keys():
		var resource_key := str(key)
		var current_resource := int(role_state.get_resource(resource_key, 0))
		var resource_delta := int(resource_deltas[key])
		var next_resource := apply_resource_delta(current_resource, resource_delta)
		role_state.set_resource(resource_key, next_resource)

	return {"ok": true, "role": role_state.to_dict()}
