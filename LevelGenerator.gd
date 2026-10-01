extends Node3D
class_name LevelGenerator
## Процедурный генератор города для Taxi Master.
## При старте сцены строит: землю, сетку дорог с разметкой и тротуарами,
## дома из CSGBox3D, случайные препятствия на дорогах и финишную зону.
## Ничего верстать вручную не нужно — просто повесьте скрипт на Node3D.

signal level_generated(spawn_transform: Transform3D, finish_position: Vector3)
signal finish_reached(body: Node3D)

@export_group("Генерация")
@export var seed_value: int = 0              ## 0 = случайный сид при каждом запуске
@export var generate_on_ready: bool = true

@export_group("Сетка города")
@export_range(2, 20) var blocks_x: int = 6   ## кварталов по X
@export_range(2, 20) var blocks_z: int = 6   ## кварталов по Z
@export var block_size: float = 30.0         ## размер квартала (м)
@export var road_width: float = 10.0         ## ширина проезжей части (м)
@export var sidewalk_width: float = 2.0
@export var sidewalk_height: float = 0.2

@export_group("Дома")
@export var min_building_height: float = 6.0
@export var max_building_height: float = 40.0
@export_range(1, 4) var max_buildings_per_side: int = 3
@export_range(0.0, 1.0) var park_chance: float = 0.12  ## шанс квартала-парка без домов

@export_group("Препятствия")
@export_range(0, 300) var obstacle_count: int = 40
@export var safe_radius: float = 15.0        ## без препятствий вокруг старта/финиша

@export_group("Финиш")
@export var finish_size: Vector3 = Vector3(8, 4, 8)
@export var min_finish_distance_ratio: float = 0.6  ## доля от макс. расстояния по карте

var rng := RandomNumberGenerator.new()
var spawn_transform: Transform3D
var finish_position: Vector3

var _cell: float
var _root: Node3D
var _mats := {}


func _ready() -> void:
	if generate_on_ready:
		generate()


## Полная (пере)генерация уровня. Можно вызывать повторно для нового города.
func generate() -> void:
	if seed_value == 0:
		rng.randomize()
	else:
		rng.seed = seed_value
	print("[LevelGenerator] seed = ", rng.seed)

	if _root:
		_root.queue_free()
	_root = Node3D.new()
	_root.name = "City"
	add_child(_root)

	_cell = block_size + road_width
	_make_materials()
	_build_environment()
	_build_ground()
	_build_roads()
	_build_blocks()
	_pick_spawn_and_finish()
	_build_finish()
	_build_obstacles()
	_ensure_camera()

	level_generated.emit(spawn_transform, finish_position)


# ---------------------------------------------------------------- helpers

func _road_coord(i: int) -> float:
	return i * _cell

func _city_size() -> Vector2:
	return Vector2(blocks_x * _cell, blocks_z * _cell)

func _mat(color: Color, rough := 0.9, emissive := false, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	m.roughness = rough
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if emissive:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.5
	return m

func _make_materials() -> void:
	_mats = {
		"ground": _mat(Color(0.25, 0.45, 0.2)),
		"asphalt": _mat(Color(0.12, 0.12, 0.13), 0.95),
		"line_white": _mat(Color(0.95, 0.95, 0.95)),
		"line_yellow": _mat(Color(1.0, 0.8, 0.1)),
		"sidewalk": _mat(Color(0.6, 0.6, 0.58)),
		"park": _mat(Color(0.2, 0.55, 0.2)),
		"trunk": _mat(Color(0.35, 0.22, 0.1)),
		"leaves": _mat(Color(0.15, 0.5, 0.15)),
		"cone": _mat(Color(1.0, 0.45, 0.0), 0.6),
		"barrier": _mat(Color(0.9, 0.1, 0.1), 0.6),
		"crate": _mat(Color(0.6, 0.42, 0.2)),
		"window": _mat(Color(0.9, 0.85, 0.5), 0.3, true),
		"finish": _mat(Color(0.1, 1.0, 0.3), 0.5, true, 0.35),
		"finish_pole": _mat(Color(0.1, 1.0, 0.3), 0.5, true),
	}
	var palette := [
		Color(0.85, 0.75, 0.6), Color(0.7, 0.35, 0.3), Color(0.55, 0.6, 0.7),
		Color(0.9, 0.9, 0.85), Color(0.45, 0.45, 0.5), Color(0.8, 0.6, 0.4),
		Color(0.6, 0.7, 0.6), Color(0.95, 0.8, 0.7),
	]
	for i in palette.size():
		_mats["building_%d" % i] = _mat(palette[i], 0.8)

## Создаёт CSGBox3D с коллизией.
func _box(parent: Node, name_: String, size: Vector3, pos: Vector3, mat: Material,
		collide := true, rot_y := 0.0) -> CSGBox3D:
	var b := CSGBox3D.new()
	b.name = name_
	b.size = size
	b.position = pos
	b.rotation.y = rot_y
	b.material = mat
	b.use_collision = collide
	parent.add_child(b)
	return b

func _group(name_: String) -> Node3D:
	var n := Node3D.new()
	n.name = name_
	_root.add_child(n)
	return n


# ---------------------------------------------------------------- world

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	_root.add_child(sun)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.9)
	sky_mat.sky_horizon_color = Color(0.75, 0.85, 0.95)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.002
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	_root.add_child(we)

func _build_ground() -> void:
	var s := _city_size()
	var margin := 80.0
	_box(_root, "Ground", Vector3(s.x + margin * 2, 1.0, s.y + margin * 2),
		Vector3(s.x / 2, -0.5, s.y / 2), _mats.ground)

func _build_roads() -> void:
	var g := _group("Roads")
	var s := _city_size()
	var h := 0.1
	var len_x := s.x + road_width
	var len_z := s.y + road_width
	# Дороги вдоль X (по каждой линии Z)
	for j in blocks_z + 1:
		var z := _road_coord(j)
		_box(g, "RoadX_%d" % j, Vector3(len_x, h, road_width), Vector3(s.x / 2, h / 2, z), _mats.asphalt)
		_lane_markings(g, Vector3(0, 0, z), true, s.x)
	# Дороги вдоль Z
	for i in blocks_x + 1:
		var x := _road_coord(i)
		_box(g, "RoadZ_%d" % i, Vector3(road_width, h + 0.002, len_z), Vector3(x, h / 2 + 0.001, s.y / 2), _mats.asphalt)
		_lane_markings(g, Vector3(x, 0, 0), false, s.y)

## Прерывистая центральная линия на отрезках между перекрёстками + стоп-линии.
func _lane_markings(parent: Node, origin: Vector3, along_x: bool, length: float) -> void:
	var dash := 3.0
	var gap := 3.0
	var y := 0.115
	var segments := blocks_x if along_x else blocks_z
	for k in segments:
		var a := _road_coord(k) + road_width / 2 + 1.0
		var b := _road_coord(k + 1) - road_width / 2 - 1.0
		var t := a
		while t + dash <= b:
			var c := t + dash / 2
			var pos := Vector3(c, y, origin.z) if along_x else Vector3(origin.x, y, c)
			var size := Vector3(dash, 0.01, 0.25) if along_x else Vector3(0.25, 0.01, dash)
			_box(parent, "Dash", size, pos, _mats.line_yellow, false)
			t += dash + gap
		# стоп-линии у перекрёстков
		for end in [a - 0.5, b + 0.5]:
			var p2 := Vector3(end, y, origin.z + road_width / 4) if along_x else Vector3(origin.x - road_width / 4, y, end)
			if end > a: # противоположная полоса у дальнего перекрёстка
				p2 = Vector3(end, y, origin.z - road_width / 4) if along_x else Vector3(origin.x + road_width / 4, y, end)
			var s2 := Vector3(0.4, 0.01, road_width / 2 - 0.4) if along_x else Vector3(road_width / 2 - 0.4, 0.01, 0.4)
			_box(parent, "StopLine", s2, p2, _mats.line_white, false)

func _build_blocks() -> void:
	var g := _group("Blocks")
	for i in blocks_x:
		for j in blocks_z:
			var cx := _road_coord(i) + _cell / 2
			var cz := _road_coord(j) + _cell / 2
			var block := Node3D.new()
			block.name = "Block_%d_%d" % [i, j]
			block.position = Vector3(cx, 0, cz)
			g.add_child(block)
			# тротуар-подиум на весь квартал
			_box(block, "Sidewalk", Vector3(block_size, sidewalk_height, block_size),
				Vector3(0, sidewalk_height / 2, 0), _mats.sidewalk)
			if rng.randf() < park_chance:
				_build_park(block)
			else:
				_build_buildings(block)

func _build_park(block: Node3D) -> void:
	var inner := block_size - sidewalk_width * 2
	_box(block, "Lawn", Vector3(inner, 0.05, inner), Vector3(0, sidewalk_height + 0.025, 0), _mats.park, false)
	for n in rng.randi_range(5, 12):
		var p := Vector3(rng.randf_range(-inner / 2 + 2, inner / 2 - 2), sidewalk_height,
			rng.randf_range(-inner / 2 + 2, inner / 2 - 2))
		var th := rng.randf_range(2.0, 3.5)
		_box(block, "Trunk", Vector3(0.5, th, 0.5), p + Vector3(0, th / 2, 0), _mats.trunk)
		var ls := rng.randf_range(2.0, 3.5)
		_box(block, "Leaves", Vector3(ls, ls, ls), p + Vector3(0, th + ls / 2, 0), _mats.leaves, false)

## Делит квартал на участки по периметру и ставит дома разной высоты.
func _build_buildings(block: Node3D) -> void:
	var inner := block_size - sidewalk_width * 2
	var n := rng.randi_range(1, max_buildings_per_side)
	if n == 1 and rng.randf() < 0.5:
		# один большой дом на весь квартал
		_spawn_building(block, Vector3.ZERO, Vector2(inner, inner))
		return
	var cell := inner / n
	for a in n:
		for b in n:
			var w := cell - rng.randf_range(0.5, 2.5)
			var d := cell - rng.randf_range(0.5, 2.5)
			var x := -inner / 2 + cell * (a + 0.5)
			var z := -inner / 2 + cell * (b + 0.5)
			_spawn_building(block, Vector3(x, 0, z), Vector2(w, d))

func _spawn_building(block: Node3D, local_pos: Vector3, footprint: Vector2) -> void:
	# ближе к центру города дома выше
	var s := _city_size()
	var world := block.position + local_pos
	var center_dist := Vector2(world.x - s.x / 2, world.z - s.y / 2).length() / (s.length() / 2)
	var hmax := lerpf(max_building_height, min_building_height * 1.5, clampf(center_dist, 0, 1))
	var h := rng.randf_range(min_building_height, maxf(hmax, min_building_height + 1))
	h = snappedf(h, 3.0)
	var mat: Material = _mats["building_%d" % rng.randi_range(0, 7)]
	var b := _box(block, "Building", Vector3(footprint.x, h, footprint.y),
		local_pos + Vector3(0, sidewalk_height + h / 2, 0), mat)
	# Крыша-парапет — вычитаем внутренность (демонстрация CSG-операций)
	var cut := CSGBox3D.new()
	cut.operation = CSGShape3D.OPERATION_SUBTRACTION
	cut.size = Vector3(footprint.x - 1.0, 1.0, footprint.y - 1.0)
	cut.position = Vector3(0, h / 2, 0)
	b.add_child(cut)
	# Полосы "окон" по этажам (декор, без коллизий)
	var floors := int(h / 3.0)
	for f in range(1, floors):
		if rng.randf() < 0.35:
			continue
		var y := sidewalk_height + f * 3.0 - 1.0
		var strip := CSGBox3D.new()
		strip.size = Vector3(footprint.x + 0.1, 0.8, footprint.y + 0.1)
		strip.position = local_pos + Vector3(0, y, 0)
		strip.material = _mats.window
		block.add_child(strip)
		var core := CSGBox3D.new() # оставляем только тонкую рамку снаружи
		core.operation = CSGShape3D.OPERATION_SUBTRACTION
		core.size = Vector3(footprint.x - 0.1, 1.0, footprint.y - 0.1)
		strip.add_child(core)


## Если в сцене нет камеры — ставим обзорную, чтобы сразу увидеть город.
func _ensure_camera() -> void:
	if get_viewport().get_camera_3d() != null:
		return
	var s := _city_size()
	var cam := Camera3D.new()
	cam.name = "OverviewCamera"
	cam.far = 2000
	_root.add_child(cam)
	var center := Vector3(s.x / 2, 0, s.y / 2)
	cam.look_at_from_position(center + Vector3(0, s.length() * 0.6, s.y * 0.75), center)
	cam.current = true


# ---------------------------------------------------------------- gameplay

func _intersection(i: int, j: int) -> Vector3:
	return Vector3(_road_coord(i), 0, _road_coord(j))

func _pick_spawn_and_finish() -> void:
	# старт — случайный угол карты
	var si := 0 if rng.randf() < 0.5 else blocks_x
	var sj := 0 if rng.randf() < 0.5 else blocks_z
	var spawn := _intersection(si, sj)
	# смотрим в сторону центра по одной из дорог
	var dir := Vector3(1 if si == 0 else -1, 0, 0)
	var origin := spawn + Vector3(0, 1.0, 0)
	spawn_transform = Transform3D(Basis(), origin).looking_at(origin + dir, Vector3.UP)

	var max_dist := _city_size().length()
	var candidates: Array[Vector3] = []
	for i in blocks_x + 1:
		for j in blocks_z + 1:
			var p := _intersection(i, j)
			if p.distance_to(spawn) >= max_dist * min_finish_distance_ratio:
				candidates.append(p)
	if candidates.is_empty():
		candidates.append(_intersection(blocks_x - si, blocks_z - sj))
	finish_position = candidates[rng.randi_range(0, candidates.size() - 1)]

	var marker := Marker3D.new()
	marker.name = "SpawnPoint"
	marker.transform = spawn_transform
	marker.add_to_group("spawn_point")
	_root.add_child(marker)

func _build_finish() -> void:
	var area := Area3D.new()
	area.name = "FinishZone"
	area.position = finish_position + Vector3(0, finish_size.y / 2, 0)
	area.add_to_group("finish_zone")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = finish_size
	shape.shape = box
	area.add_child(shape)
	area.body_entered.connect(func(body: Node3D): finish_reached.emit(body))
	_root.add_child(area)

	# визуал: полупрозрачный объём + столбы + светящаяся рамка
	var vis := CSGBox3D.new()
	vis.size = finish_size
	vis.material = _mats.finish
	area.add_child(vis)
	var hx := finish_size.x / 2
	var hz := finish_size.z / 2
	for c in [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(-hx, hz), Vector2(hx, hz)]:
		var pole := CSGCylinder3D.new()
		pole.radius = 0.2
		pole.height = finish_size.y + 2
		pole.position = Vector3(c.x, 1, c.y)
		pole.material = _mats.finish_pole
		area.add_child(pole)
	var light := OmniLight3D.new()
	light.light_color = Color(0.2, 1, 0.4)
	light.omni_range = 15
	light.light_energy = 2
	light.position = Vector3(0, finish_size.y, 0)
	area.add_child(light)

## Случайные точки на дорогах (не на перекрёстках и не у старта/финиша).
func _random_road_point() -> Vector3:
	var along_x := rng.randf() < 0.5
	var line := rng.randi_range(0, blocks_z if along_x else blocks_x)
	var seg := rng.randi_range(0, (blocks_x if along_x else blocks_z) - 1)
	var t := _road_coord(seg) + road_width / 2 + rng.randf_range(2.0, block_size - 2.0)
	var lateral := rng.randf_range(-road_width / 2 + 1.0, road_width / 2 - 1.0)
	if along_x:
		return Vector3(t, 0.1, _road_coord(line) + lateral)
	return Vector3(_road_coord(line) + lateral, 0.1, t)

func _build_obstacles() -> void:
	var g := _group("Obstacles")
	var spawn := spawn_transform.origin
	var placed := 0
	var tries := 0
	while placed < obstacle_count and tries < obstacle_count * 20:
		tries += 1
		var p := _random_road_point()
		if p.distance_to(spawn) < safe_radius or p.distance_to(finish_position) < safe_radius:
			continue
		match rng.randi_range(0, 3):
			0: _spawn_cones(g, p)
			1: _spawn_barrier(g, p)
			2: _spawn_crates(g, p)
			3: _spawn_pothole_bump(g, p)
		placed += 1

func _spawn_cones(g: Node, p: Vector3) -> void:
	for k in rng.randi_range(1, 4):
		var c := CSGCylinder3D.new()
		c.name = "Cone"
		c.cone = true
		c.radius = 0.35
		c.height = 0.8
		c.sides = 12
		c.material = _mats.cone
		c.use_collision = true
		c.position = p + Vector3(k * 1.2, 0.4, rng.randf_range(-0.3, 0.3))
		g.add_child(c)

func _spawn_barrier(g: Node, p: Vector3) -> void:
	var rot := rng.randf_range(0, TAU)
	_box(g, "Barrier", Vector3(3.0, 1.0, 0.4), p + Vector3(0, 0.5, 0), _mats.barrier, true, rot)

func _spawn_crates(g: Node, p: Vector3) -> void:
	for k in rng.randi_range(1, 3):
		var s := rng.randf_range(0.8, 1.4)
		_box(g, "Crate", Vector3(s, s, s),
			p + Vector3(rng.randf_range(-1, 1), s / 2 + (k - 1) * 0.0, rng.randf_range(-1, 1)),
			_mats.crate, true, rng.randf_range(0, TAU))

func _spawn_pothole_bump(g: Node, p: Vector3) -> void:
	# лежачий полицейский поперёк дороги — пассажирам понравится :)
	var along_x := fmod(absf(p.z), _cell) < road_width / 2 or fmod(absf(p.z), _cell) > _cell - road_width / 2
	var size := Vector3(0.6, 0.15, road_width - 1.0) if along_x else Vector3(road_width - 1.0, 0.15, 0.6)
	var bump_pos := p
	if along_x:
		bump_pos.z = roundf(p.z / _cell) * _cell
	else:
		bump_pos.x = roundf(p.x / _cell) * _cell
	_box(g, "SpeedBump", size, bump_pos + Vector3(0, 0.075, 0), _mats.line_yellow)
