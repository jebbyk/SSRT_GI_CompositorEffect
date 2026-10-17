extends SceneTree
## Temporary diagnostic: capture the main viewport + the albedo SubViewport and
## sample representative pixels, so we can objectively see whether the background
## (sky) is black or light-blue. Run with a real driver, NOT --headless.

func _init() -> void:
	var packed: PackedScene = load("res://test_scene.tscn")
	var scene: Node = packed.instantiate()
	root.add_child(scene)

	# Let the 3D scene, sky and (if it runs) the compositor settle.
	for i in range(50):
		await process_frame

	var main_img: Image = root.get_texture().get_image()
	main_img.save_png("/tmp/opencode/main_view.png")
	var W := main_img.get_width()
	var H := main_img.get_height()
	print("MAIN VIEW: %dx%d" % [W, H])
	print("  top-center (sky?)   : ", main_img.get_pixel(W / 2, 8))
	print("  upper-left          : ", main_img.get_pixel(20, 20))
	print("  center              : ", main_img.get_pixel(W / 2, H / 2))
	var sky_sum := Color(0, 0, 0)
	var sky_n := 0
	for y in range(0, H / 4, 4):
		for x in range(0, W, 4):
			sky_sum += main_img.get_pixel(x, y)
			sky_n += 1
	print("  sky avg (top 1/4)   : ", sky_sum / sky_n)

	var sub: Node = scene.get_node_or_null("SubViewport")
	if sub:
		var sub_img: Image = sub.get_texture().get_image()
		sub_img.save_png("/tmp/opencode/subview.png")
		var SW := sub_img.get_width()
		var SH := sub_img.get_height()
		print("SUBVIEW: %dx%d" % [SW, SH])
		print("  top-center        : ", sub_img.get_pixel(SW / 2, 8))
		print("  center            : ", sub_img.get_pixel(SW / 2, SH / 2))

	var we: Node = scene.get_node_or_null("WorldEnvironment")
	if we:
		var env: Environment = we.environment
		print("MAIN ENV background_mode=", env.background_mode,
			" (0=CLEAR,1=COLOR,2=SKY), sky=", env.sky != null)

	quit(0)
