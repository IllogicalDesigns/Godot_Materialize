extends Node
## Save dialog probe: the three save dialogs, running as Godot's own FileDialogs
## (ACCESS_FILESYSTEM, not the OS chooser), must carry a real UI press all the
## way to the write handlers. Run with
## `DISPLAY=:1 godot --path . res://tests/save_dialog_probe.tscn`:
## instantiate `main.tscn` via the exported references the way
## `full_live.gd` does, create a metallic map through the panel the way
## `tests/material_live.gd` does, assert every dialog is filesystem-access and
## NOT native (the native half is dead on this system: the portal response
## match rule in Godot's X11 display server carries `destination=`, and the
## bus daemon strips that header when forwarding a directed signal, so the
## match never fires and no pick ever arrives — verified with the two-process
## control in `tools/portal_destination_test/`), then press each dialog's real
## ok button and check what lands: the maps and `materialize_material.res` in
## the folder, the single-map PNG, and the source loaded back from a file the
## dialog's own list.
##
## Every widget the test drives is a shell `@export` reference, never a node
## path (`CODING_RULES.md`). FileDialog builds its UI as internal children, so
## the press target is the dialog's own `get_ok_button()`, the file list is
## found by walking `get_children(true)`, and each dialog must be pointed at an
## absolute path, the way a typed/pasted path arrives.

const PHASE_START := 0
const PHASE_METALLIC := 1
const PHASE_CHECK := 2
const PHASE_PRESSED := 3
const PHASE_CHOOSE := 4
const PHASE_FILES := 5
const PHASE_SAVE_MAP := 6
const PHASE_SAVED := 7
const PHASE_SELECT := 9
const PHASE_SOURCE := 10

## The brick brown `tests/material_live.gd` drives, so the map is created.
const BRICK := Color(0.45, 0.22, 0.17)

## The material file the shell writes, mirroring `main.gd`'s `MATERIAL_FILE`.
const MATERIAL_FILE := "materialize_material.res"

## The single map Save Map writes, and the map file Load opens back.
const SAVED_MAP := "probe_saved_metallic.png"

var _phase := PHASE_START
var _main: Node
var _frames := 0
var _done := false
var _picked := ""
## The folder the dialogs are pointed at, the way the user types/pastes a path.
## A filesystem-access dialog browses real paths, so the folder is an absolute
## path under the user data dir, not a `user://` path: Godot's filesystem
## DirAccess cannot change to a `user://` path, so a `user://` `current_dir`
## leaves the dialog where it was.
var _folder := OS.get_user_data_dir().path_join("save_dialog_probe")

func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)

func _process(_delta: float) -> void:
	if _done:
		return
	_frames += 1
	if _frames > 3600:
		_fail("timed out in phase %d" % _phase)
		return
	match _phase:
		PHASE_START:
			if not _main._status.text.contains("ready"):
				return
			_main._activate(_main.modules["metallic"])
			var panel: Control = _main._panel_slot.get_child(0) as Control
			panel.metal_color_picker.color = BRICK
			panel.weight_faders[0].slider.value = 1.0
			panel.weight_faders[1].slider.value = 0.0
			panel.weight_faders[2].slider.value = 0.0
			panel.weight_faders[3].slider.value = 0.0
			panel.weight_faders[4].slider.value = 0.5
			_main.boxes[3].create_button.pressed.emit()
			_phase += 1
		PHASE_METALLIC:
			if not _main._status.text.contains("ready"):
				return
			_check(_main.maps["metallic"] != null, "the metallic map is created")
			_phase += 1
		PHASE_CHECK:
			# The native half is broken on this system, so the working dialogs
			# are Godot's own, browsing the real filesystem. The portal
			# destination-header finding is documented in
			# `tools/portal_destination_test/`.
			var ok := true
			for d: FileDialog in [_main._load_dialog, _main._save_dialog,
					_main._save_all_dialog]:
				if d.access != FileDialog.ACCESS_FILESYSTEM:
					ok = false
				if d.use_native_dialog:
					ok = false
			_check(ok, "every FileDialog is Godot's own dialog browsing the " \
					+ "real filesystem (native is dead here, see the header)")
			# `mode` in the scene set Window.mode (minimized/fullscreen), so the
			# file modes are the scene's `file_mode` keys: the folder dialog must
			# be in Open Folder mode, the only mode that emits dir_selected.
			_check(_main._save_all_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR,
					"the folder dialog is in Open Folder mode, the mode that " \
							+ "emits dir_selected, got %d" \
							% _main._save_all_dialog.file_mode)
			_check(_main._save_dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE,
					"the single-map dialog is in Save mode, got %d" \
							% _main._save_dialog.file_mode)
			_check(_main._load_dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE,
					"the load dialog is in Open File mode, got %d" \
							% _main._load_dialog.file_mode)
			_phase += 1
		PHASE_PRESSED:
			_main._save_material_button.pressed.emit()
			var dialog: FileDialog = _main._save_all_dialog
			_check(dialog.title == "Save Material Folder",
					"the button opens the folder dialog for the material export")
			_check(dialog.visible, "the dialog is on screen")
			DirAccess.make_dir_recursive_absolute(_folder)
			dialog.dir_selected.connect(_on_dir_selected)
			dialog.current_dir = _folder
			var ok_button: Button = dialog.get_ok_button()
			_check(ok_button != null, "the folder dialog has an ok button")
			print("[save_dialog_probe] ok button: '", ok_button.text,
					"' disabled=", ok_button.disabled,
					" dialog dir=", dialog.get_current_dir())
			_phase += 1
		PHASE_CHOOSE:
			# The user's press, the way a press works: the dialog's real ok
			# button, driving `dir_selected` into the shell's handler.
			_main._save_all_dialog.get_ok_button().pressed.emit()
			_phase += 1
		PHASE_FILES:
			_check(_picked != "", "the dialog press emits dir_selected")
			_check(_picked == _folder, "the dialog emits the folder it is in, " \
					+ "picked '%s', dialog dir '%s'" % [_picked, _folder])
			var status: String = _main._status.text
			_check(status.contains("maps and the material"),
					"the status reports the material export: %s" % [status])
			var access := DirAccess.open(_folder)
			_check(access != null, "the export folder exists at %s" % [_folder])
			var metal: Image = _main.maps["metallic"]
			var map_file := "%s/materialize_metallic.png" % _folder
			_check(FileAccess.file_exists(map_file),
					"the metallic map file is written by the dialog press")
			if metal != null and FileAccess.file_exists(map_file):
				var saved: Image = Image.load_from_file(map_file)
				_check(saved != null and saved.get_size() == metal.get_size(),
						"the written map is the map, at %s" % [saved.get_size()
								if saved != null else Vector2i()])
			var material_path := "%s/%s" % [_folder, MATERIAL_FILE]
			_check(FileAccess.file_exists(material_path),
					"the material file is written by the dialog press")
			var material: StandardMaterial3D = ResourceLoader.load(
					material_path, "", ResourceLoader.CACHE_MODE_IGNORE)
			_check(material != null, "the material file loads back as a material")
			if material != null:
				var slot: Image = null
				if material.metallic_texture != null:
					slot = material.metallic_texture.get_image()
				_check(slot != null and slot.get_size() == metal.get_size(),
						"the material's metallic slot carries the map at " \
								+ "%s, got %s" % [metal.get_size(),
								(slot.get_size() if slot != null else Vector2i())])
			_phase += 1
			print("[save_dialog_probe] material export written, pressing Save Map")
		PHASE_SAVE_MAP:
			_main._save_map_button.pressed.emit()
			var save: FileDialog = _main._save_dialog
			_check(save.title == "Save a Map",
					"the Save Map button opens the single-map dialog")
			_check(save.visible, "the single-map dialog is on screen")
			save.current_dir = _folder
			save.current_file = SAVED_MAP
			save.get_ok_button().pressed.emit()
			_phase += 1
		PHASE_SAVED:
			var status2: String = _main._status.text
			_check(status2.contains("Saved"),
					"the single-map press reports a save: %s" % [status2])
			var saved_file := "%s/%s" % [_folder, SAVED_MAP]
			_check(FileAccess.file_exists(saved_file),
					"the Save Map press writes %s" % [saved_file])
			var metal2: Image = _main.maps["metallic"]
			if FileAccess.file_exists(saved_file):
				var saved2: Image = Image.load_from_file(saved_file)
				_check(saved2 != null and saved2.get_size() == metal2.get_size(),
						"the Save Map file is the map at %s" % [metal2.get_size()])
			_main._load_diffuse_button.pressed.emit()
			var load_dialog: FileDialog = _main._load_dialog
			_check(load_dialog.title == "Load a diffuse image",
					"the Load button opens the load dialog")
			_check(load_dialog.visible, "the load dialog is on screen")
			load_dialog.current_dir = _folder
			_phase = PHASE_SELECT
			print("[save_dialog_probe] single map written, picking it in the load dialog")
		PHASE_SELECT:
			var list := _file_list(_main._load_dialog)
			if list == null:
				_fail("the load dialog has no file list (internal children)")
				return
			var target := -1
			for i in list.get_item_count():
				var meta: Dictionary = list.get_item_metadata(i)
				if not meta.get("dir", false) \
						and meta.get("name", "") == "materialize_metallic.png":
					target = i
			if target < 0:
				# The list fills a frame after the dialog changes dir, so wait.
				return
			_check(list.get_item_count() > 0,
					"the load dialog lists the folder it is pointed at")
			list.select(target)
			_main._load_dialog.current_file = "materialize_metallic.png"
			_main._load_dialog.get_ok_button().pressed.emit()
			_phase += 1
		PHASE_SOURCE:
			var source: Image = _main.maps["diffuse_original"]
			_check(source != null,
					"the load press puts the picked file in the source store")
			if source == null:
				return
			_check(source.get_size() == Vector2i(1024, 1024),
					"the loaded source is at the working size, got %s" \
							% [source.get_size()])
			print("[save_dialog_probe] PASS: the ok presses picked ", _picked,
					", wrote the maps and the material, wrote ", SAVED_MAP,
					", and loaded the map back as the source")
			_done = true
			get_tree().quit()

## The dialog's own answer to the press, logged so the shell handler's debug
## prints can be compared with the path the dialog emits.
func _on_dir_selected(path: String) -> void:
	_picked = path
	print("[save_dialog_probe] dialog emits dir_selected: '", path, "'")

## The dialog's file list: FileDialog builds its UI as internal children, so the
## walk uses `get_children(true)`, the same way the panel tests walk children.
func _file_list(dialog: FileDialog) -> ItemList:
	var nodes: Array[Node] = [dialog]
	while not nodes.is_empty():
		var n: Node = nodes.pop_back()
		for c in n.get_children(true):
			if c is ItemList:
				return c as ItemList
			nodes.append(c)
	return null

func _fail(note: String) -> void:
	print("[save_dialog_probe] FAIL: ", note)
	_done = true
	get_tree().quit()

func _check(condition: bool, note: String) -> void:
	if not condition:
		_fail(note)
