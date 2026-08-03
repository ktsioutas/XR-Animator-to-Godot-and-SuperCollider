class_name SCRokokoReader
extends Object


## Rokoko Reader Script
##
## This script implements a basic Rokoko packet reader. The listen method is
## used to start the UDP server. The poll method should be called to poll for
## incoming packets. Packets are decoded and dispatched through the
## on_rokoko_packet signal.


## Rokoko packet received signal
signal on_rokoko_packet(data : RokokoBody.BodyData)

# UDP Server
var _server : UDPServer = UDPServer.new()
# var _server : SCRokokoOscServer = SCRokokoOscServer.new()

# Current connection
var _connection : PacketPeerUDP

# Body data
var _data := RokokoBody.BodyData.new()

# OSC parser
var _osc_parser := SCRokokoOscParser.new()

var _osc_data := SCRokokoOscData.new()

var osc_addr : StringName = &"/rokoko/"
var in_vals = []
var prev_vals = []

# Diagnostics. The first valid packet and then every Nth valid packet are
# summarized. Unexpected OSC addresses are printed only when the set of
# addresses changes, so OSCGroups control traffic cannot flood the Output.
var diagnostics_enabled : bool = true
var valid_packet_log_interval : int = 120
var _received_packet_count : int = 0
var _valid_packet_count : int = 0
var _last_ignored_signature : String = ""

## Stop listening
func stop() -> void:
	_server.stop()
	_connection = null


## Start listening
func listen(p_port : int = GodSCRokokoTrackerPlugin.OSC_PORT_DEFAULT) -> void:
	stop()
	var listen_error := _server.listen(p_port)
	if listen_error != OK:
		push_error(
			"[SCRokokoReader] Could not listen on UDP port %d (error %d)."
			% [p_port, listen_error])
		return

	print(
		"[SCRokokoReader] Listening | UDP port=%d | OSC address=%s"
		% [p_port, osc_addr])

# func received_message(address, vals, time):
# 	# if (address as StringName) != osc_addr \
# 	# 	or (vals[1] as StringName) != skel_name:
# 	# 	return
# 	vals.pop_front()
# 	vals.pop_front()
# 	print(vals.slice(0, 10))
# 	if prev_vals != vals:
# 		in_vals = vals

# 	#if not vals is Array:
# 		#vals = [vals]
# 	#full_message = [address, vals, time]
# 	#if prev_vals != vals:
# 		#in_vals = vals
# 		## print("in_vals: %s" % in_vals)
# 		## print("type of in_vals: %s" % type_string(typeof(in_vals)))
# 		## print(in_vals.slice(0, 10))

## Poll for incoming packets
func poll() -> void:
	var poll_error := _server.poll()
	if poll_error != OK:
		push_error("[SCRokokoReader] UDP poll failed with error %d." % poll_error)
		return

	# Keep the existing PacketPeerUDP. take_connection() returns null when no
	# *new* endpoint is pending; assigning that null result directly would lose
	# the already accepted OSCGroups/SuperCollider peer.
	while _server.is_connection_available():
		var new_connection := _server.take_connection()
		if new_connection:
			_connection = new_connection
			print(
				"[SCRokokoReader] Accepted UDP peer %s:%d"
				% [
					_connection.get_packet_ip(),
					_connection.get_packet_port(),
				])

	if not _connection:
		return

	# Loop processing the incoming packets
	while _connection.get_available_packet_count() > 0:
		var packet := _connection.get_packet()
		_received_packet_count += 1

		# SCRokokoOscParser keeps its dictionary between calls. Clear it here so
		# this UDP datagram cannot accidentally reuse /rokoko/ values from an
		# earlier packet. This lets the reader remain safe without requiring a
		# separate modification to sc_rokoko_osc_parser.gd.
		_osc_parser.incoming_messages.clear()
		var msg := _osc_parser.parse(packet)
		_process_osc(msg)

		# Get the packet as UTF8
		# var packet := _connection.get_packet().get_string_from_utf8()

		# # Decode the JSON packet
		# var json := JSON.parse_string(packet)

		# # Reject if not dictionary
		# if typeof(json) != TYPE_DICTIONARY:
		# 	continue

		# # Process the data
		# _process_json(json)

# Process received OSC data
func _process_osc(msg : Dictionary) -> void:
	# OSCGroups or another sender may deliver control/status addresses on the
	# same UDP route. Only /rokoko/ contains the sc-dance body payload.
	if not msg.has(osc_addr):
		_log_ignored_packet(msg)
		return

	var raw_vals = msg.get(osc_addr, [])
	if typeof(raw_vals) != TYPE_ARRAY:
		push_warning(
			"[SCRokokoReader] Ignored /rokoko/ payload of type %s."
			% type_string(typeof(raw_vals)))
		return

	# pop_front() must operate on a copy, not on the parser's stored array.
	var vals : Array = raw_vals.duplicate()
	if vals.size() < 3:
		push_warning(
			"[SCRokokoReader] Ignored incomplete /rokoko/ packet with %d values."
			% vals.size())
		return

	_valid_packet_count += 1
	_log_valid_packet(vals)

	# sc-dance prefixes the body values with two metadata values.
	vals.pop_front()
	vals.pop_front()

	_osc_data.parse(vals, _data)

	# Process the metadata
	_data.has_torso = true
	_data.has_fingers = false
	_data.has_face = false

	# Report the packet
	# print(_data.positions)
	# print(_data.rotations)
	on_rokoko_packet.emit(_data)


func _log_ignored_packet(msg : Dictionary) -> void:
	if not diagnostics_enabled:
		return

	var signature := str(msg.keys())
	if signature == _last_ignored_signature:
		return

	_last_ignored_signature = signature
	print(
		"[SCRokokoReader] Ignored packet #%d | OSC address(es)=%s"
		% [_received_packet_count, signature])


func _log_valid_packet(vals : Array) -> void:
	if not diagnostics_enabled:
		return

	var interval := maxi(valid_packet_log_interval, 1)
	if _valid_packet_count != 1 and _valid_packet_count % interval != 0:
		return

	var metadata := vals.slice(0, mini(2, vals.size()))
	var preview_end := mini(10, vals.size())
	var body_preview := vals.slice(2, preview_end)
	print(
		"[SCRokokoReader] Valid /rokoko/ packet #%d | values=%d | metadata=%s | body-preview=%s"
		% [
			_valid_packet_count,
			vals.size(),
			str(metadata),
			str(body_preview),
		])


# # Process received json data
# func _process_json(json : Dictionary) -> void:
# 	# Get the actor
# 	var actor : Dictionary = json.scene.actors[0]

# 	# Process the metadata
# 	_data.has_torso = actor.meta.hasBody
# 	_data.has_fingers = actor.meta.hasGloves
# 	_data.has_face = actor.meta.hasFace

# 	# Process the body
# 	if _data.has_torso:
# 		_process_body(actor.body)

# 	if _data.has_face:
# 		_process_face(actor.face)

# 	# Report the packet
# 	on_rokoko_packet.emit(_data)


# # Process received body
# func _process_body(body : Dictionary) -> void:
# 	# Process all body entries
# 	for key in body:
# 		# Get the joint
# 		var joint : RokokoBody.Joint = RokokoBody.JOINT_NAMES.get(key, -1)
# 		if joint < 0:
# 			continue

# 		# Get the data
# 		var data : Dictionary = body[key]
# 		var pos : Dictionary = data.position
# 		var rot : Dictionary = data.rotation

# 		# Set the position and rotation
# 		_data.positions[joint] = Vector3(pos.x, pos.y, -pos.z)
# 		_data.rotations[joint] = Quaternion(rot.x, rot.y, -rot.z, -rot.w)


# # Process received face
# func _process_face(face : Dictionary) -> void:
# 	# Process all face entries
# 	for key in face:
# 		# Get the blend
# 		var blend : RokokoBody.FaceBlend = RokokoBody.FACE_BLEND_NAMES.get(key, -1)
# 		if blend < 0:
# 			continue

# 		# Set the face blend
# 		_data.face_blends[blend] = face[key] * 0.01
