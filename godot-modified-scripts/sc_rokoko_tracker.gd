# Deliberately no `class_name` here. Some projects expose the tracker as an
# Autoload/global named SCRokokoTracker; declaring the same global script class
# would make Godot report that this script hides an existing global class.
extends Node


## Rokoko Tracker Node
##
## This node provides a Rokoko tracker as a scene-tree node. It may also
## be instantiated as an autoload to provide for multiple trackers on different
## ports.


## Face tracker name
@export_category("Tracker names")
@export var face_tracker_name : String = GodSCRokokoTrackerPlugin.FACE_TRACKER_NAME_DEFAULT

## Body tracker name
@export var body_tracker_name : String = GodSCRokokoTrackerPlugin.BODY_TRACKER_NAME_DEFAULT

## Position mode
@export_category("Tracking")
@export_enum("Free", "Calibrate", "Locked") var position_mode : int = GodSCRokokoTrackerPlugin.POSITION_MODE_DEFAULT

## UDP listener port
@export_category("Network")
@export var udp_listener_port : int = GodSCRokokoTrackerPlugin.OSC_PORT_DEFAULT


# Tracker source
var _source : SCRokokoSource


# On entering the scene-tree, construct the tracker source and start listening
# for incoming packets.
func _enter_tree() -> void:
	if body_tracker_name.is_empty():
		push_error("[SCRokokoTracker] Body tracker name cannot be empty.")
		set_process(false)
		return

	if udp_listener_port < 1 or udp_listener_port > 65535:
		push_error(
			"[SCRokokoTracker] Invalid UDP listener port: %d"
			% udp_listener_port)
		set_process(false)
		return

	print(
		"[SCRokokoTracker] Starting | UDP port=%d | OSC=/rokoko/ | body tracker=%s"
		% [udp_listener_port, body_tracker_name])

	_source = SCRokokoSource.new(
		face_tracker_name,
		body_tracker_name,
		position_mode,
		udp_listener_port)

	var registered_tracker := XRServer.get_tracker(body_tracker_name)
	if registered_tracker is XRBodyTracker:
		print(
			"[SCRokokoTracker] Registered body tracker: ",
			body_tracker_name)
	else:
		push_warning(
			"[SCRokokoTracker] Body tracker was not registered: %s"
			% body_tracker_name)


# On frame processing, poll the tracker source for updates.
func _process(_delta: float) -> void:
	if _source != null:
		_source.poll()
