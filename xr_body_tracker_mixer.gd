class_name XRBodyTrackerMixer
extends Node


## Combines or selects body-tracking data already decoded inside Godot.
##
## Inputs:
##   - Iannis / SuperCollider: /sc/rokoko/body_tracker
##   - XR Animator / VMC:     /vmc/body_tracker
##
## Output:
##   - Final avatar tracker:  /merged/body_tracker
##
## Attach this script to one Node that is created before the avatar scenes.
## Point every XRBodyModifier3D and matching XRNode3D at output_tracker_name.


enum OperatingMode {
	AUTO_SELECT,
	SC_ONLY,
	VMC_ONLY,
	SC_BODY_VMC_HEAD,
}


@export_category("Tracker names")
@export var sc_tracker_name: StringName = &"/sc/rokoko/body_tracker"
@export var vmc_tracker_name: StringName = &"/vmc/body_tracker"
@export var output_tracker_name: StringName = &"/merged/body_tracker"

@export_category("Source selection")
@export_enum("Auto select", "SuperCollider only", "VMC only", "SC body + VMC head")
var operating_mode: int = OperatingMode.AUTO_SELECT
@export var prefer_vmc_in_auto_mode: bool = true
@export var fallback_to_other_full_body_source: bool = true

@export_category("Head mixing")
## In SC_BODY_VMC_HEAD mode, keep the head position attached to the SC body
## and use only the VMC user's head rotation.
@export var auto_calibrate_head_on_first_valid_frame: bool = true
@export var keep_body_head_position: bool = true

@export_category("Diagnostics")
@export var print_status: bool = true
@export_range(0.25, 30.0, 0.25) var status_interval_seconds: float = 2.0
@export var print_root_and_head_positions: bool = false


var _output_tracker: XRBodyTracker
var _head_calibrated: bool = false
var _head_calibration_requested: bool = false
var _head_neutral_relative: Quaternion = Quaternion.IDENTITY
var _body_head_rest_relative: Quaternion = Quaternion.IDENTITY
var _last_status_time_ms: int = 0
var _last_effective_source: String = ""


func _ready() -> void:
	_register_output_tracker()
	_last_status_time_ms = Time.get_ticks_msec()


func _exit_tree() -> void:
	if _output_tracker == null:
		return

	var registered := XRServer.get_tracker(output_tracker_name)
	if registered == _output_tracker:
		XRServer.remove_tracker(_output_tracker)


func _process(_delta: float) -> void:
	if _output_tracker == null:
		return

	var sc_tracker := _get_body_tracker(sc_tracker_name)
	var vmc_tracker := _get_body_tracker(vmc_tracker_name)
	var effective_source := "none"

	match operating_mode:
		OperatingMode.AUTO_SELECT:
			effective_source = _process_auto_select(sc_tracker, vmc_tracker)

		OperatingMode.SC_ONLY:
			effective_source = _process_single_source(
				sc_tracker,
				vmc_tracker,
				"SuperCollider",
				"VMC")

		OperatingMode.VMC_ONLY:
			effective_source = _process_single_source(
				vmc_tracker,
				sc_tracker,
				"VMC",
				"SuperCollider")

		OperatingMode.SC_BODY_VMC_HEAD:
			effective_source = _process_sc_body_vmc_head(sc_tracker, vmc_tracker)

		_:
			_set_output_inactive()

	if effective_source != _last_effective_source:
		_last_effective_source = effective_source
		if print_status:
			print("[XRBodyTrackerMixer] Active source changed to: ", effective_source)

	_print_periodic_status(sc_tracker, vmc_tracker, effective_source)


## Call this while both users are looking straight ahead.
## It is only used by SC_BODY_VMC_HEAD mode.
func calibrate_head() -> void:
	_head_calibration_requested = true
	_head_calibrated = false
	print("[XRBodyTrackerMixer] Head calibration requested.")


func reset_head_calibration() -> void:
	_head_calibration_requested = false
	_head_calibrated = false
	_head_neutral_relative = Quaternion.IDENTITY
	_body_head_rest_relative = Quaternion.IDENTITY
	print("[XRBodyTrackerMixer] Head calibration cleared.")


func set_operating_mode(new_mode: int) -> void:
	if new_mode < OperatingMode.AUTO_SELECT or new_mode > OperatingMode.SC_BODY_VMC_HEAD:
		push_error("XRBodyTrackerMixer: Invalid operating mode %d" % new_mode)
		return

	operating_mode = new_mode
	print("[XRBodyTrackerMixer] Mode set to: ", _mode_name())


func _register_output_tracker() -> void:
	var existing := XRServer.get_tracker(output_tracker_name)
	if existing != null:
		push_error(
			"XRBodyTrackerMixer: A tracker named '%s' already exists. " % output_tracker_name
			+ "Choose another output_tracker_name or remove the duplicate producer.")
		set_process(false)
		return

	_output_tracker = XRBodyTracker.new()
	_output_tracker.name = output_tracker_name
	_output_tracker.description = "Merged SuperCollider and VMC body tracker"
	XRServer.add_tracker(_output_tracker)
	print("[XRBodyTrackerMixer] Registered output tracker: ", output_tracker_name)


func _get_body_tracker(tracker_name: StringName) -> XRBodyTracker:
	var tracker := XRServer.get_tracker(tracker_name)
	if tracker is XRBodyTracker:
		return tracker as XRBodyTracker
	return null


func _tracker_is_live(tracker: XRBodyTracker) -> bool:
	return tracker != null and tracker.has_tracking_data


func _process_auto_select(
		sc_tracker: XRBodyTracker,
		vmc_tracker: XRBodyTracker) -> String:
	var preferred := vmc_tracker if prefer_vmc_in_auto_mode else sc_tracker
	var alternate := sc_tracker if prefer_vmc_in_auto_mode else vmc_tracker
	var preferred_name := "VMC" if prefer_vmc_in_auto_mode else "SuperCollider"
	var alternate_name := "SuperCollider" if prefer_vmc_in_auto_mode else "VMC"

	if _tracker_is_live(preferred):
		_copy_full_tracker(preferred)
		return preferred_name

	if _tracker_is_live(alternate):
		_copy_full_tracker(alternate)
		return alternate_name + " (automatic fallback)"

	_set_output_inactive()
	return "none"


func _process_single_source(
		primary: XRBodyTracker,
		fallback: XRBodyTracker,
		primary_name: String,
		fallback_name: String) -> String:
	if _tracker_is_live(primary):
		_copy_full_tracker(primary)
		return primary_name

	if fallback_to_other_full_body_source and _tracker_is_live(fallback):
		_copy_full_tracker(fallback)
		return fallback_name + " (fallback)"

	_set_output_inactive()
	return "none"


func _process_sc_body_vmc_head(
		sc_tracker: XRBodyTracker,
		vmc_tracker: XRBodyTracker) -> String:
	if not _tracker_is_live(sc_tracker):
		if fallback_to_other_full_body_source and _tracker_is_live(vmc_tracker):
			_copy_full_tracker(vmc_tracker)
			return "VMC full body (SC body unavailable)"

		_set_output_inactive()
		return "none"

	_copy_full_tracker(sc_tracker)

	if not _tracker_is_live(vmc_tracker):
		return "SuperCollider body (VMC head unavailable)"

	if not _head_inputs_are_valid(sc_tracker, vmc_tracker):
		return "SuperCollider body (VMC head invalid)"

	if not _head_calibrated:
		if auto_calibrate_head_on_first_valid_frame or _head_calibration_requested:
			_capture_head_calibration(sc_tracker, vmc_tracker)
		else:
			return "SuperCollider body (head awaiting calibration)"

	_apply_vmc_head_rotation(sc_tracker, vmc_tracker)
	return "SuperCollider body + VMC head"


func _copy_full_tracker(source: XRBodyTracker) -> void:
	for joint in range(XRBodyTracker.JOINT_MAX):
		var flags := source.get_joint_flags(joint)
		_output_tracker.set_joint_flags(joint, flags)
		if flags != 0:
			_output_tracker.set_joint_transform(joint, source.get_joint_transform(joint))

	_output_tracker.body_flags = source.body_flags
	_output_tracker.has_tracking_data = source.has_tracking_data
	_publish_default_pose()


func _set_output_inactive() -> void:
	for joint in range(XRBodyTracker.JOINT_MAX):
		_output_tracker.set_joint_flags(joint, 0)

	_output_tracker.body_flags = 0
	_output_tracker.has_tracking_data = false
	_output_tracker.invalidate_pose(&"default")


func _publish_default_pose() -> void:
	if not _output_tracker.has_tracking_data:
		_output_tracker.invalidate_pose(&"default")
		return

	var root_flags := _output_tracker.get_joint_flags(XRBodyTracker.JOINT_ROOT)
	var root := _output_tracker.get_joint_transform(XRBodyTracker.JOINT_ROOT)

	if root_flags == 0:
		root = _output_tracker.get_joint_transform(XRBodyTracker.JOINT_HIPS)

	_output_tracker.set_pose(
		&"default",
		root,
		Vector3.ZERO,
		Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _head_inputs_are_valid(
		body_tracker: XRBodyTracker,
		head_tracker: XRBodyTracker) -> bool:
	return (
			_joint_has_position(body_tracker, XRBodyTracker.JOINT_HEAD)
			and _joint_has_orientation(body_tracker, XRBodyTracker.JOINT_NECK)
			and _joint_has_orientation(body_tracker, XRBodyTracker.JOINT_HEAD)
			and _joint_has_orientation(head_tracker, XRBodyTracker.JOINT_NECK)
			and _joint_has_orientation(head_tracker, XRBodyTracker.JOINT_HEAD))


func _joint_has_position(tracker: XRBodyTracker, joint: int) -> bool:
	var flags := tracker.get_joint_flags(joint)
	return (flags & XRBodyTracker.JOINT_FLAG_POSITION_VALID) != 0


func _joint_has_orientation(tracker: XRBodyTracker, joint: int) -> bool:
	var flags := tracker.get_joint_flags(joint)
	return (flags & XRBodyTracker.JOINT_FLAG_ORIENTATION_VALID) != 0


func _capture_head_calibration(
		body_tracker: XRBodyTracker,
		head_tracker: XRBodyTracker) -> void:
	var body_neck_q := body_tracker.get_joint_transform(
		XRBodyTracker.JOINT_NECK).basis.get_rotation_quaternion().normalized()
	var body_head_q := body_tracker.get_joint_transform(
		XRBodyTracker.JOINT_HEAD).basis.get_rotation_quaternion().normalized()
	var head_neck_q := head_tracker.get_joint_transform(
		XRBodyTracker.JOINT_NECK).basis.get_rotation_quaternion().normalized()
	var head_head_q := head_tracker.get_joint_transform(
		XRBodyTracker.JOINT_HEAD).basis.get_rotation_quaternion().normalized()

	_body_head_rest_relative = (body_neck_q.inverse() * body_head_q).normalized()
	_head_neutral_relative = (head_neck_q.inverse() * head_head_q).normalized()
	_head_calibration_requested = false
	_head_calibrated = true
	print("[XRBodyTrackerMixer] Head calibrated. Both users should now remain in their normal tracking positions.")


func _apply_vmc_head_rotation(
		body_tracker: XRBodyTracker,
		head_tracker: XRBodyTracker) -> void:
	var body_neck_transform := body_tracker.get_joint_transform(XRBodyTracker.JOINT_NECK)
	var body_head_transform := body_tracker.get_joint_transform(XRBodyTracker.JOINT_HEAD)
	var head_neck_transform := head_tracker.get_joint_transform(XRBodyTracker.JOINT_NECK)
	var head_head_transform := head_tracker.get_joint_transform(XRBodyTracker.JOINT_HEAD)

	var body_neck_q := body_neck_transform.basis.get_rotation_quaternion().normalized()
	var head_neck_q := head_neck_transform.basis.get_rotation_quaternion().normalized()
	var head_head_q := head_head_transform.basis.get_rotation_quaternion().normalized()

	# Remove the head user's neck/body orientation, calculate head movement
	# relative to calibration, and then attach it to the body user's neck.
	var current_head_relative := (head_neck_q.inverse() * head_head_q).normalized()
	var head_delta := (_head_neutral_relative.inverse() * current_head_relative).normalized()
	var output_head_q := (
		body_neck_q * _body_head_rest_relative * head_delta).normalized()

	var output_head_position := body_head_transform.origin
	if not keep_body_head_position:
		output_head_position = head_head_transform.origin

	var output_head_transform := Transform3D(
		Basis(output_head_q),
		output_head_position)

	var body_flags := body_tracker.get_joint_flags(XRBodyTracker.JOINT_HEAD)
	var head_flags := head_tracker.get_joint_flags(XRBodyTracker.JOINT_HEAD)
	var position_flags := body_flags & (
		XRBodyTracker.JOINT_FLAG_POSITION_VALID
		| XRBodyTracker.JOINT_FLAG_POSITION_TRACKED)
	var orientation_flags := head_flags & (
		XRBodyTracker.JOINT_FLAG_ORIENTATION_VALID
		| XRBodyTracker.JOINT_FLAG_ORIENTATION_TRACKED)

	_output_tracker.set_joint_transform(XRBodyTracker.JOINT_HEAD, output_head_transform)
	_output_tracker.set_joint_flags(
		XRBodyTracker.JOINT_HEAD,
		position_flags | orientation_flags)

	_apply_head_tip(body_tracker, output_head_transform)


func _apply_head_tip(
		body_tracker: XRBodyTracker,
		output_head_transform: Transform3D) -> void:
	var tip_flags := body_tracker.get_joint_flags(XRBodyTracker.JOINT_HEAD_TIP)
	if tip_flags == 0:
		return

	var body_head := body_tracker.get_joint_transform(XRBodyTracker.JOINT_HEAD)
	var body_tip := body_tracker.get_joint_transform(XRBodyTracker.JOINT_HEAD_TIP)
	var relative_tip := body_head.affine_inverse() * body_tip
	var output_tip := output_head_transform * relative_tip

	_output_tracker.set_joint_transform(XRBodyTracker.JOINT_HEAD_TIP, output_tip)
	_output_tracker.set_joint_flags(XRBodyTracker.JOINT_HEAD_TIP, tip_flags)


func _print_periodic_status(
		sc_tracker: XRBodyTracker,
		vmc_tracker: XRBodyTracker,
		effective_source: String) -> void:
	if not print_status:
		return

	var now := Time.get_ticks_msec()
	if now - _last_status_time_ms < int(status_interval_seconds * 1000.0):
		return

	_last_status_time_ms = now
	var output_state := "LIVE" if _output_tracker.has_tracking_data else "WAITING"
	var message := (
		"[XRBodyTrackerMixer] mode=%s | SC=%s | VMC=%s | output=%s | source=%s | head_calibrated=%s"
		% [
			_mode_name(),
			_tracker_state(sc_tracker),
			_tracker_state(vmc_tracker),
			output_state,
			effective_source,
			str(_head_calibrated),
		])

	if print_root_and_head_positions and _output_tracker.has_tracking_data:
		var root_position := _output_tracker.get_joint_transform(
			XRBodyTracker.JOINT_ROOT).origin
		var head_position := _output_tracker.get_joint_transform(
			XRBodyTracker.JOINT_HEAD).origin
		message += " | root=%s | head=%s" % [root_position, head_position]

	print(message)


func _tracker_state(tracker: XRBodyTracker) -> String:
	if tracker == null:
		return "NOT_REGISTERED"
	if tracker.has_tracking_data:
		return "LIVE"
	return "NO_DATA"


func _mode_name() -> String:
	match operating_mode:
		OperatingMode.AUTO_SELECT:
			return "AUTO_SELECT"
		OperatingMode.SC_ONLY:
			return "SC_ONLY"
		OperatingMode.VMC_ONLY:
			return "VMC_ONLY"
		OperatingMode.SC_BODY_VMC_HEAD:
			return "SC_BODY_VMC_HEAD"
		_:
			return "UNKNOWN"
