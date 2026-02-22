extends Control

const SAVE_PATH := "user://save.cfg"
const MOUSE_POINTER_ID := -100

const START_SPAWN_INTERVAL := 1.2
const MIN_SPAWN_INTERVAL := 0.35
const START_BOMB_LIFETIME := 5.0
const MIN_BOMB_LIFETIME := 1.8
const START_BOMB_SPEED := 260.0
const MAX_BOMB_SPEED := 520.0
const PICK_MARGIN := 18.0
const WARNING_START_SECONDS := 3.0
const BOMB_SIZE_RATIO := 0.09
const BOMB_MIN_SIDE := 34.0
const SPRITE_ANIM_FPS := 1.25
const SHADOW_WIDTH_RATIO := 0.74
const SHADOW_HEIGHT_RATIO := 0.20
const SHADOW_GAP_RATIO := -0.10
const SHADOW_ALPHA := 0.30

const BOMB_RED := "RED"
const BOMB_BLUE := "BLUE"
const BOMB_YELLOW := "YELLOW"
const BOMB_GREEN := "GREEN"

const RED_SPRITE_PATHS: Array[String] = [
	"res://assets/sprites/red1.png",
	"res://assets/sprites/red2.png",
]
const BLUE_SPRITE_PATHS: Array[String] = [
	"res://assets/sprites/blue1.png",
	"res://assets/sprites/blue2.png",
]
const GREEN_SPRITE_PATHS: Array[String] = [
	"res://assets/sprites/green1.png",
	"res://assets/sprites/green2.png",
]
const YELLOW_SPRITE_PATHS: Array[String] = [
	"res://assets/sprites/yellow1.png",
	"res://assets/sprites/yellow2.png",
]

enum GameState {
	PLAYING,
	GAME_OVER,
}

@onready var play_area: Control = $gates

@onready var left_top_gate: ColorRect = $"gates/2gate"
@onready var left_bottom_gate: ColorRect = $"gates/1gate"
@onready var right_top_gate: ColorRect = $"gates/4gate"
@onready var right_bottom_gate: ColorRect = $"gates/3gate"

@onready var score_label: Label = $HUD/ScoreBox/HBox/ScoreLabel
@onready var best_label: Label = $HUD/ScoreBox/HBox/BestLabel
@onready var score_box: Panel = $HUD/ScoreBox
@onready var game_over_panel: Panel = $GameOverPanel
@onready var game_over_text: Label = $GameOverPanel/VBox/GameOverText
@onready var restart_button: Button = $GameOverPanel/VBox/RestartButton

@onready var top_left_zone: ColorRect = $ZonesArea/RedZone
@onready var top_right_zone: ColorRect = $ZonesArea/BlueZone
@onready var bottom_left_zone: ColorRect = $ZonesArea/yellowZone
@onready var bottom_right_zone: ColorRect = $ZonesArea/GreenZone

var game_state: GameState = GameState.PLAYING
var score := 0
var best_score := 0

var spawn_interval := START_SPAWN_INTERVAL
var bomb_lifetime := START_BOMB_LIFETIME
var bomb_speed := START_BOMB_SPEED
var spawn_accumulator := 0.0

var bombs: Array[Dictionary] = []
var sprite_variant_cache: Dictionary = {}

var dragging_bomb: ColorRect = null
var dragging_pointer_id := -9999
var drag_offset := Vector2.ZERO


func _ready() -> void:
	randomize()
	restart_button.pressed.connect(_on_restart_pressed)
	load_best_score()
	apply_pixel_font_if_available()
	reset_game()


func _process(delta: float) -> void:
	if game_state != GameState.PLAYING:
		return

	spawn_accumulator += delta
	while spawn_accumulator >= spawn_interval:
		spawn_accumulator -= spawn_interval
		spawn_bomb()

	for i in range(bombs.size() - 1, -1, -1):
		var bomb_data: Dictionary = bombs[i]
		var bomb_node: ColorRect = bomb_data["node"]
		if not is_instance_valid(bomb_node):
			bombs.remove_at(i)
			continue

		var parked := bool(bomb_data.get("parked", false))
		if not parked:
			bomb_data["lifetime"] = float(bomb_data["lifetime"]) - delta
			if float(bomb_data["lifetime"]) <= 0.0:
				trigger_game_over("Time up")
				return

		if bomb_node != dragging_bomb:
			if parked:
				move_bomb_inside_zone(bomb_data, delta)
			else:
				move_bomb_with_bounce(bomb_data, delta)

		update_bomb_shadow_transform(bomb_data)
		update_bomb_sprite_animation(bomb_data, delta)
		update_bomb_warning_visual(bomb_data)
		bombs[i] = bomb_data


func _input(event: InputEvent) -> void:
	if game_state != GameState.PLAYING:
		return

	if event is InputEventScreenTouch:
		handle_screen_touch(event)
		return

	if event is InputEventScreenDrag:
		handle_screen_drag(event)
		return

	if event is InputEventMouseButton:
		handle_mouse_button(event)
		return

	if event is InputEventMouseMotion:
		handle_mouse_motion(event)


func handle_screen_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if dragging_bomb == null:
			start_drag(event.position, event.index)
	else:
		if dragging_bomb != null and dragging_pointer_id == event.index:
			finish_drag(event.position)


func handle_screen_drag(event: InputEventScreenDrag) -> void:
	if dragging_bomb == null:
		return
	if dragging_pointer_id != event.index:
		return
	update_drag_position(event.position)


func handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		if dragging_bomb == null:
			start_drag(event.position, MOUSE_POINTER_ID)
	else:
		if dragging_bomb != null and dragging_pointer_id == MOUSE_POINTER_ID:
			finish_drag(event.position)


func handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if dragging_bomb == null:
		return
	if dragging_pointer_id != MOUSE_POINTER_ID:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return
	update_drag_position(event.position)


func start_drag(pointer_position: Vector2, pointer_id: int) -> void:
	var picked := get_bomb_at_screen_position(pointer_position)
	if picked == null:
		return

	dragging_bomb = picked
	dragging_pointer_id = pointer_id
	drag_offset = pointer_position - dragging_bomb.global_position
	reorder_dragging_bomb_to_front()


func update_drag_position(pointer_position: Vector2) -> void:
	if dragging_bomb == null:
		return

	var viewport_size := get_viewport_rect().size
	var target := pointer_position - drag_offset
	target.x = clampf(target.x, 0.0, viewport_size.x - dragging_bomb.size.x)
	target.y = clampf(target.y, 0.0, viewport_size.y - dragging_bomb.size.y)

	dragging_bomb.global_position = target


func finish_drag(_pointer_position: Vector2) -> void:
	if dragging_bomb == null:
		return

	var released_bomb := dragging_bomb
	clear_drag_state()

	var dropped_zone: Variant = zone_for_bomb(released_bomb)
	var expected_zone: Variant = expected_zone_for_type(str(released_bomb.get_meta("bomb_type")))

	if dropped_zone == null:
		return

	if dropped_zone == expected_zone:
		score += 1
		update_hud()
		park_bomb_in_zone(released_bomb, expected_zone)
		apply_difficulty_step_if_needed()
	else:
		trigger_game_over("Wrong zone")


func move_bomb_with_bounce(bomb_data: Dictionary, delta: float) -> void:
	var bomb: ColorRect = bomb_data["node"]
	var velocity: Vector2 = bomb_data["velocity"]
	var viewport_size := get_viewport_rect().size
	var min_x := 0.0
	var max_x := maxf(0.0, viewport_size.x - bomb.size.x)
	var min_y := score_box.get_global_rect().end.y + 4.0
	var max_y := maxf(min_y, viewport_size.y - bomb.size.y)
	var obstacle_rects: Array[Rect2] = get_zone_obstacle_rects_global()

	var travel_distance := velocity.length() * delta
	var steps: int = maxi(1, int(ceil(travel_distance / 10.0)))
	var step_delta := delta / float(steps)

	for _step in range(steps):
		var new_pos := bomb.global_position + velocity * step_delta

		if new_pos.x <= min_x:
			new_pos.x = min_x
			velocity.x = absf(velocity.x)
		elif new_pos.x >= max_x:
			new_pos.x = max_x
			velocity.x = -absf(velocity.x)

		if new_pos.y <= min_y:
			new_pos.y = min_y
			velocity.y = absf(velocity.y)
		elif new_pos.y >= max_y:
			new_pos.y = max_y
			velocity.y = -absf(velocity.y)

		var bomb_rect := Rect2(new_pos, bomb.size)
		for obstacle: Rect2 in obstacle_rects:
			if not bomb_rect.intersects(obstacle):
				continue

			var overlap_x := minf(bomb_rect.end.x, obstacle.end.x) - maxf(bomb_rect.position.x, obstacle.position.x)
			var overlap_y := minf(bomb_rect.end.y, obstacle.end.y) - maxf(bomb_rect.position.y, obstacle.position.y)
			if overlap_x <= 0.0 or overlap_y <= 0.0:
				continue

			if overlap_x < overlap_y:
				if bomb_rect.get_center().x < obstacle.get_center().x:
					bomb_rect.position.x -= overlap_x
				else:
					bomb_rect.position.x += overlap_x
				velocity.x = -velocity.x
			else:
				if bomb_rect.get_center().y < obstacle.get_center().y:
					bomb_rect.position.y -= overlap_y
				else:
					bomb_rect.position.y += overlap_y
				velocity.y = -velocity.y

		bomb_rect.position.x = clampf(bomb_rect.position.x, min_x, max_x)
		bomb_rect.position.y = clampf(bomb_rect.position.y, min_y, max_y)
		bomb.global_position = bomb_rect.position

	bomb_data["velocity"] = velocity


func move_bomb_inside_zone(bomb_data: Dictionary, delta: float) -> void:
	var bomb: ColorRect = bomb_data["node"]
	var velocity: Vector2 = bomb_data["velocity"]
	var zone_rect: Rect2 = bomb_data["park_rect"]
	var new_pos := bomb.global_position + velocity * delta

	var min_x := zone_rect.position.x
	var max_x := zone_rect.end.x - bomb.size.x
	var min_y := zone_rect.position.y
	var max_y := zone_rect.end.y - bomb.size.y

	if new_pos.x <= min_x:
		new_pos.x = min_x
		velocity.x = absf(velocity.x)
	elif new_pos.x >= max_x:
		new_pos.x = max_x
		velocity.x = -absf(velocity.x)

	if new_pos.y <= min_y:
		new_pos.y = min_y
		velocity.y = absf(velocity.y)
	elif new_pos.y >= max_y:
		new_pos.y = max_y
		velocity.y = -absf(velocity.y)

	bomb.global_position = new_pos
	bomb_data["velocity"] = velocity


func park_bomb_in_zone(node: ColorRect, zone: ColorRect) -> void:
	var zone_rect: Rect2 = zone.get_global_rect()
	var bomb_rect := Rect2(node.global_position, node.size)
	node.z_index = 20

	var min_x := zone_rect.position.x
	var max_x := zone_rect.end.x - node.size.x
	var min_y := zone_rect.position.y
	var max_y := zone_rect.end.y - node.size.y
	bomb_rect.position.x = clampf(bomb_rect.position.x, min_x, max_x)
	bomb_rect.position.y = clampf(bomb_rect.position.y, min_y, max_y)
	node.global_position = bomb_rect.position

	for i in range(bombs.size() - 1, -1, -1):
		if bombs[i]["node"] == node:
			var data: Dictionary = bombs[i]
			data["parked"] = true
			data["park_rect"] = zone_rect
			data["velocity"] = Vector2(randf_range(-0.6, 0.6), randf_range(-0.6, 0.6)).normalized() * (bomb_speed * 0.45)
			bombs[i] = data
			break


func get_zone_obstacle_rects_global() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	var zones: Array[ColorRect] = [top_left_zone, top_right_zone, bottom_left_zone, bottom_right_zone]
	for zone: ColorRect in zones:
		rects.append(zone.get_global_rect())
	return rects


func intersects_any_zone_obstacle_global(rect: Rect2) -> bool:
	var obstacle_rects: Array[Rect2] = get_zone_obstacle_rects_global()
	for obstacle: Rect2 in obstacle_rects:
		if rect.intersects(obstacle):
			return true
	return false


func expected_zone_for_type(bomb_type: String):
	match bomb_type:
		BOMB_RED:
			return top_left_zone
		BOMB_BLUE:
			return top_right_zone
		BOMB_YELLOW:
			return bottom_left_zone
		BOMB_GREEN:
			return bottom_right_zone
		_:
			return null


func zone_for_position(global_position: Vector2):
	if Rect2(top_left_zone.global_position, top_left_zone.size).has_point(global_position):
		return top_left_zone
	if Rect2(top_right_zone.global_position, top_right_zone.size).has_point(global_position):
		return top_right_zone
	if Rect2(bottom_left_zone.global_position, bottom_left_zone.size).has_point(global_position):
		return bottom_left_zone
	if Rect2(bottom_right_zone.global_position, bottom_right_zone.size).has_point(global_position):
		return bottom_right_zone
	return null


func zone_for_bomb(node: ColorRect):
	var bomb_center: Vector2 = node.global_position + (node.size * 0.5)
	return zone_for_position(bomb_center)


func spawn_bomb() -> void:
	var bomb := ColorRect.new()
	bomb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bomb.z_index = 10

	var bomb_type := random_bomb_type()
	bomb.color = color_for_type(bomb_type)

	var viewport_size := get_viewport_rect().size
	var bomb_side := maxf(BOMB_MIN_SIDE, viewport_size.x * BOMB_SIZE_RATIO)
	bomb.custom_minimum_size = Vector2(bomb_side, bomb_side)
	bomb.size = Vector2(bomb_side, bomb_side)

	var shadow_node: Panel = create_bomb_shadow(bomb_side)
	play_area.add_child(shadow_node)

	var sprite_node: TextureRect = apply_bomb_visual_variant(bomb, bomb_type)

	play_area.add_child(bomb)

	var spawn_data: Dictionary = get_spawn_data(bomb_side)
	bomb.position = spawn_data["position"]
	update_shadow_position(shadow_node, bomb)

	bomb.set_meta("bomb_type", bomb_type)
	var bomb_data := {
		"node": bomb,
		"shadow_node": shadow_node,
		"lifetime": bomb_lifetime,
		"start_lifetime": bomb_lifetime,
		"velocity": spawn_data["velocity"],
	}
	if sprite_node != null:
		bomb_data["sprite_node"] = sprite_node
		bomb_data["anim_time"] = randf()

	bombs.append(bomb_data)


func create_bomb_shadow(bomb_side: float) -> Panel:
	var shadow := Panel.new()
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.z_index = 5
	shadow.custom_minimum_size = Vector2(bomb_side * SHADOW_WIDTH_RATIO, bomb_side * SHADOW_HEIGHT_RATIO)
	shadow.size = shadow.custom_minimum_size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, SHADOW_ALPHA)
	var radius := int(shadow.size.y * 0.5)
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	shadow.add_theme_stylebox_override("panel", style)
	return shadow


func update_bomb_shadow_transform(bomb_data: Dictionary) -> void:
	var bomb: ColorRect = bomb_data["node"]
	if not is_instance_valid(bomb):
		return
	var shadow: Panel = bomb_data.get("shadow_node") as Panel
	if shadow == null or not is_instance_valid(shadow):
		return
	update_shadow_position(shadow, bomb)
	shadow.visible = bomb.visible


func update_shadow_position(shadow: Panel, bomb: ColorRect) -> void:
	var shadow_x := bomb.position.x + ((bomb.size.x - shadow.size.x) * 0.5)
	var shadow_y := bomb.position.y + bomb.size.y + (bomb.size.y * SHADOW_GAP_RATIO)
	shadow.position = Vector2(shadow_x, shadow_y)


func apply_bomb_visual_variant(bomb: ColorRect, bomb_type: String) -> TextureRect:
	var variants: Array = get_sprite_variants_for_type(bomb_type)
	if variants.is_empty():
		return null

	# Bomb keeps the same logical square; only sprite is visible.
	bomb.color = Color(1.0, 1.0, 1.0, 0.0)
	var sprite: TextureRect = TextureRect.new()
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sprite.layout_mode = 1
	sprite.anchor_left = 0.0
	sprite.anchor_top = 0.0
	sprite.anchor_right = 1.0
	sprite.anchor_bottom = 1.0
	sprite.offset_left = 0.0
	sprite.offset_top = 0.0
	sprite.offset_right = 0.0
	sprite.offset_bottom = 0.0
	sprite.grow_horizontal = 2
	sprite.grow_vertical = 2
	sprite.stretch_mode = TextureRect.STRETCH_SCALE
	sprite.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = variants[0]
	bomb.add_child(sprite)
	return sprite


func update_bomb_sprite_animation(bomb_data: Dictionary, delta: float) -> void:
	var sprite: TextureRect = bomb_data.get("sprite_node") as TextureRect
	if sprite == null or not is_instance_valid(sprite):
		return

	var bomb: ColorRect = bomb_data["node"]
	var bomb_type := str(bomb.get_meta("bomb_type"))
	var variants: Array = get_sprite_variants_for_type(bomb_type)
	if variants.size() <= 1:
		return

	var anim_time := float(bomb_data.get("anim_time", 0.0)) + delta
	bomb_data["anim_time"] = anim_time
	var frame: int = int(floor(anim_time * SPRITE_ANIM_FPS)) % variants.size()
	sprite.texture = variants[frame]


func get_sprite_variants_for_type(bomb_type: String) -> Array:
	match bomb_type:
		BOMB_RED:
			return get_or_load_sprite_variants("red", RED_SPRITE_PATHS)
		BOMB_BLUE:
			return get_or_load_sprite_variants("blue", BLUE_SPRITE_PATHS)
		BOMB_GREEN:
			return get_or_load_sprite_variants("green", GREEN_SPRITE_PATHS)
		BOMB_YELLOW:
			return get_or_load_sprite_variants("yellow", YELLOW_SPRITE_PATHS)
		_:
			return []


func get_or_load_sprite_variants(cache_key: String, paths: Array[String]) -> Array:
	if sprite_variant_cache.has(cache_key):
		return sprite_variant_cache[cache_key]

	var variants: Array = []
	for path in paths:
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path)
		if tex != null:
			variants.append(tex)

	sprite_variant_cache[cache_key] = variants
	return variants


func random_bomb_type() -> String:
	var roll := randi() % 4
	match roll:
		0:
			return BOMB_RED
		1:
			return BOMB_BLUE
		2:
			return BOMB_YELLOW
		_:
			return BOMB_GREEN


func color_for_type(bomb_type: String) -> Color:
	match bomb_type:
		BOMB_RED:
			return Color(0.58, 0.14, 0.14, 1.0)
		BOMB_BLUE:
			return Color(0.11, 0.28, 0.58, 1.0)
		BOMB_YELLOW:
			return Color(0.64, 0.52, 0.13, 1.0)
		_:
			return Color(0.13, 0.47, 0.19, 1.0)


func update_bomb_warning_visual(bomb_data: Dictionary) -> void:
	var bomb: ColorRect = bomb_data["node"]
	if not is_instance_valid(bomb):
		return

	if bool(bomb_data.get("parked", false)):
		bomb.self_modulate = Color(1.0, 1.0, 1.0, 1.0)
		return

	var remaining := float(bomb_data["lifetime"])
	if remaining > WARNING_START_SECONDS:
		bomb.self_modulate = Color(1.0, 1.0, 1.0, 1.0)
		return

	var intensity := clampf((WARNING_START_SECONDS - remaining) / WARNING_START_SECONDS, 0.0, 1.0)
	var speed := lerpf(10.0, 24.0, intensity)
	var pulse := 0.5 + (0.5 * sin(Time.get_ticks_msec() * 0.001 * speed))
	var alpha := lerpf(0.35, 1.0, pulse)
	bomb.self_modulate = Color(1.0, 1.0, 1.0, alpha)


func get_spawn_data(bomb_side: float) -> Dictionary:
	var play_global_pos: Vector2 = play_area.global_position
	var viewport_rect := Rect2(Vector2.ZERO, get_viewport_rect().size)
	var gates: Array[ColorRect] = [left_top_gate, left_bottom_gate, right_top_gate, right_bottom_gate]

	for _attempt in range(16):
		var gate: ColorRect = gates[randi() % gates.size()]
		var gate_global_rect: Rect2 = gate.get_global_rect()
		var gate_center := gate_global_rect.get_center()
		var margin := 8.0
		var y_min := gate_global_rect.position.y + margin
		var y_max := gate_global_rect.end.y - bomb_side - margin
		var spawn_y := gate_center.y - (bomb_side * 0.5)
		if y_max > y_min:
			spawn_y = randf_range(y_min, y_max)
		var spawn_x := gate_global_rect.end.x + 4.0
		var direction := Vector2.RIGHT
		if gate == right_top_gate or gate == right_bottom_gate:
			spawn_x = gate_global_rect.position.x - bomb_side - 4.0
			direction = Vector2.LEFT

		var spawn_global_pos := Vector2(spawn_x, spawn_y)
		spawn_global_pos.x = clampf(spawn_global_pos.x, viewport_rect.position.x, viewport_rect.end.x - bomb_side)
		spawn_global_pos.y = clampf(spawn_global_pos.y, viewport_rect.position.y, viewport_rect.end.y - bomb_side)
		var pos := spawn_global_pos - play_global_pos
		var spawn_rect := Rect2(spawn_global_pos, Vector2(bomb_side, bomb_side))
		if not intersects_any_zone_obstacle_global(spawn_rect):
			var angle_offset := deg_to_rad(randf_range(-55.0, 55.0))
			var velocity := direction.rotated(angle_offset).normalized() * bomb_speed
			return {
				"position": pos,
				"velocity": velocity,
			}

	var fallback_gate: ColorRect = gates[randi() % gates.size()]
	var fallback_gate_rect: Rect2 = fallback_gate.get_global_rect()
	var fallback_global_pos := fallback_gate_rect.get_center() - Vector2(bomb_side * 0.5, bomb_side * 0.5)
	fallback_global_pos.x = clampf(fallback_global_pos.x, viewport_rect.position.x, viewport_rect.end.x - bomb_side)
	fallback_global_pos.y = clampf(fallback_global_pos.y, viewport_rect.position.y, viewport_rect.end.y - bomb_side)
	var fallback_pos := fallback_global_pos - play_global_pos
	var fallback_dir := Vector2.RIGHT
	if fallback_gate == right_top_gate or fallback_gate == right_bottom_gate:
		fallback_dir = Vector2.LEFT
	var fallback_velocity := fallback_dir.rotated(deg_to_rad(randf_range(-25.0, 25.0))).normalized() * bomb_speed
	return {
		"position": fallback_pos,
		"velocity": fallback_velocity,
	}


func get_bomb_at_screen_position(screen_position: Vector2) -> ColorRect:
	var best_bomb: ColorRect = null
	var best_distance := INF

	for i in range(bombs.size() - 1, -1, -1):
		var bomb: ColorRect = bombs[i]["node"]
		if not is_instance_valid(bomb):
			continue
		if bool(bombs[i].get("parked", false)):
			continue
		var bomb_rect := Rect2(
			bomb.global_position - Vector2(PICK_MARGIN, PICK_MARGIN),
			bomb.size + Vector2(PICK_MARGIN * 2.0, PICK_MARGIN * 2.0)
		)
		if bomb_rect.has_point(screen_position):
			var center := bomb.global_position + (bomb.size * 0.5)
			var distance := center.distance_to(screen_position)
			if distance < best_distance:
				best_distance = distance
				best_bomb = bomb

	return best_bomb


func reorder_dragging_bomb_to_front() -> void:
	if dragging_bomb == null:
		return
	play_area.move_child(dragging_bomb, play_area.get_child_count() - 1)


func remove_bomb(node: ColorRect) -> void:
	for i in range(bombs.size() - 1, -1, -1):
		if bombs[i]["node"] == node:
			var shadow: Panel = bombs[i].get("shadow_node") as Panel
			if shadow != null and is_instance_valid(shadow):
				shadow.queue_free()
			bombs.remove_at(i)
			break
	if is_instance_valid(node):
		node.queue_free()


func clear_all_bombs() -> void:
	for bomb_data in bombs:
		var node: ColorRect = bomb_data["node"]
		var shadow: Panel = bomb_data.get("shadow_node") as Panel
		if is_instance_valid(node):
			node.queue_free()
		if shadow != null and is_instance_valid(shadow):
			shadow.queue_free()
	bombs.clear()


func apply_difficulty_step_if_needed() -> void:
	if score <= 0 or score % 5 != 0:
		return
	spawn_interval = maxf(MIN_SPAWN_INTERVAL, spawn_interval * 0.92)
	bomb_lifetime = maxf(MIN_BOMB_LIFETIME, bomb_lifetime * 0.95)
	bomb_speed = minf(MAX_BOMB_SPEED, bomb_speed * 1.04)


func trigger_game_over(reason: String) -> void:
	if game_state == GameState.GAME_OVER:
		return

	game_state = GameState.GAME_OVER
	clear_drag_state()

	if score > best_score:
		best_score = score
		save_best_score()

	update_hud()
	game_over_text.text = "GAME OVER\n" + reason + "\nScore: %d" % score
	game_over_panel.visible = true


func clear_drag_state() -> void:
	dragging_bomb = null
	dragging_pointer_id = -9999
	drag_offset = Vector2.ZERO


func reset_game() -> void:
	clear_all_bombs()
	clear_drag_state()

	game_state = GameState.PLAYING
	score = 0
	spawn_interval = START_SPAWN_INTERVAL
	bomb_lifetime = START_BOMB_LIFETIME
	bomb_speed = START_BOMB_SPEED
	spawn_accumulator = 0.0

	game_over_panel.visible = false
	update_hud()


func update_hud() -> void:
	score_label.text = "Score: %d" % score
	best_label.text = "Best: %d" % best_score


func _on_restart_pressed() -> void:
	reset_game()


func load_best_score() -> void:
	var cfg := ConfigFile.new()
	var result := cfg.load(SAVE_PATH)
	if result == OK:
		best_score = int(cfg.get_value("scores", "best_score", 0))
	else:
		best_score = 0


func save_best_score() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("scores", "best_score", best_score)
	cfg.save(SAVE_PATH)


func apply_pixel_font_if_available() -> void:
	var font_path := "res://assets/fonts/PressStart2P-Regular.ttf"
	if not ResourceLoader.exists(font_path):
		return

	var font_resource := load(font_path)
	if font_resource == null:
		return

	score_label.add_theme_font_override("font", font_resource)
	best_label.add_theme_font_override("font", font_resource)
	game_over_text.add_theme_font_override("font", font_resource)
	restart_button.add_theme_font_override("font", font_resource)
