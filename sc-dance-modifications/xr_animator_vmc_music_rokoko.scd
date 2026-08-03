// XR Animator VMC -> Rokoko-shaped data for SuperCollider/sc-dance
// ============================================================================
// PURPOSE
//   Receive XR Animator VMC bone packets through OSCGroups and repackage the
//   raw values into the familiar sc-dance /rokoko/ message layout.
//
// IMPORTANT
//   This is a MUSIC-DATA formatter, not a spatial avatar converter.
//   It does NOT modify positions or quaternions. Every x y z qx qy qz qw
//   value is copied exactly as received from XR Animator.
//
// OSCGroups client for the SuperCollider computer:
//   OscGroupClient.exe 165.22.82.70 22242 22546 22544 57130 \
//       iannisVMC 12345 skeletonTest test123
//
// USE
//   1. Run the OSCGroups command above.
//   2. Evaluate this entire file. The receiver starts automatically.
//   3. To feed the messages into the existing sc-dance Avatar, evaluate:
//          ~enableVmcMusicScDance.value;
//
// STOP
//          ~stopVmcMusicRokoko.value;

(

// Stop an older evaluated copy before installing the new one.
if(~stopVmcMusicRokoko.notNil) {
	~stopVmcMusicRokoko.value;
};


// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
~vmcMusicListenPort = 57130;
~vmcMusicFrameRate = 30.0;
~vmcMusicActorName = \XRAnimator;
~vmcMusicStatusInterval = 2.0;

// true:  also emit the completed frame locally as /rokoko/, so that
//        Avatar.enableRemote('/rokoko/') and other SC OSC listeners receive it.
// false: keep the frame only in ~vmcMusicLatestFrame and the callback.
~vmcMusicEmitLocalRokoko = true;


// ---------------------------------------------------------------------------
// Runtime data
// ---------------------------------------------------------------------------
~vmcMusicBones = IdentityDictionary.new;
~vmcMusicLatestFrame = nil;
~vmcMusicMissingBones = [];
~vmcMusicDirty = false;
~vmcMusicRoutine = nil;
~vmcMusicPacketCount = 0;
~vmcMusicFrameCount = 0;
~vmcMusicLastPacketTime = -1.0;
~vmcMusicLastStatusTime = Main.elapsedTime;
~vmcMusicLastFrameComplete = false;

// Iannis can replace either callback without changing the formatter.
// Values passed to ~onVmcMusicBone are:
//   boneName, [x, y, z, qx, qy, qz, qw]
~onVmcMusicBone = { |boneName, values| };

// The argument passed to ~onVmcMusicFrame is the complete /rokoko/ array.
~onVmcMusicFrame = { |rokokoFrame| };


// ---------------------------------------------------------------------------
// Fixed output format
// Each entry is: [possible VMC source names, sc-dance/Rokoko output name].
// Alternatives are only name fallbacks; no numerical calculation is done.
// ---------------------------------------------------------------------------
~vmcMusicBoneMap = [
	[[\Hips],                 \hip],
	[[\Spine],                \spine],
	[[\UpperChest, \Chest],   \chest],
	[[\Neck],                 \neck],
	[[\Head],                 \head],

	[[\LeftShoulder],         \leftShoulder],
	[[\LeftUpperArm],         \leftUpperArm],
	[[\LeftLowerArm],         \leftLowerArm],
	[[\LeftHand],             \leftHand],

	[[\RightShoulder],        \rightShoulder],
	[[\RightUpperArm],        \rightUpperArm],
	[[\RightLowerArm],        \rightLowerArm],
	[[\RightHand],            \rightHand],

	[[\LeftUpperLeg],         \leftUpLeg],
	[[\LeftLowerLeg],         \leftLeg],
	[[\LeftFoot],             \leftFoot],
	[[\LeftToes, \LeftFoot], \leftToe],
	[nil,                     \leftToeEnd],

	[[\RightUpperLeg],          \rightUpLeg],
	[[\RightLowerLeg],          \rightLeg],
	[[\RightFoot],              \rightFoot],
	[[\RightToes, \RightFoot], \rightToe],
	[nil,                       \rightToeEnd]
];


// ---------------------------------------------------------------------------
// Make one fixed-format /rokoko/ frame from the newest raw VMC values.
// The two toe-end entries are constants because VMC has no matching humanoid
// toe-end transform. They preserve the normal sc-dance message layout.
// ---------------------------------------------------------------------------
~vmcMusicMakeRokokoFrame = {
	var output, complete, missing, frame;

	output = List.new;
	output.add('/rokoko/');
	output.add(Main.elapsedTime.asFloat);
	output.add(~vmcMusicActorName);

	complete = true;
	missing = List.new;

	~vmcMusicBoneMap.do { |entry|
		var possibleSources, outputName, sourceName, values;

		possibleSources = entry[0];
		outputName = entry[1];
		if(possibleSources.isNil) {
			// Fixed placeholder used by normal sc-dance recordings for toe ends.
			output.add(outputName);
			[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0].do { |value|
				output.add(value)
			};
		} {
			sourceName = possibleSources.detect { |candidate|
				~vmcMusicBones[candidate].notNil
			};

			if(sourceName.isNil) {
				complete = false;
				missing.add(outputName);
			} {
				values = ~vmcMusicBones[sourceName];
				output.add(outputName);
				values.do { |value| output.add(value.asFloat) };
			};
		};
	};

	if(complete) {
		frame = output.asArray;
		~vmcMusicLatestFrame = frame;
		~vmcMusicFrameCount = ~vmcMusicFrameCount + 1;
		~vmcMusicLastFrameComplete = true;
		~vmcMusicMissingBones = [];

		// Direct hook for Iannis's synthesis code.
		~onVmcMusicFrame.value(frame.copy);

		// Local injection for the existing sc-dance live-input machinery.
		if(~vmcMusicEmitLocalRokoko) {
			NetAddr.localAddr.sendMsg(*frame);
		};
	} {
		~vmcMusicLastFrameComplete = false;
		~vmcMusicMissingBones = missing.asArray;
	};

	complete
};


// ---------------------------------------------------------------------------
// Status display
// ---------------------------------------------------------------------------
~vmcMusicPostStatus = {
	var age;

	if(~vmcMusicLastPacketTime < 0) {
		postf(
			"[VMC music] WAITING | no /VMC/Ext/Bone/Pos on port %\n",
			~vmcMusicListenPort
		);
	} {
		age = Main.elapsedTime - ~vmcMusicLastPacketTime;

		if(age > 2.0) {
			postf(
				"[VMC music] STALE | last packet %.2f seconds ago | packets:%\n",
				age,
				~vmcMusicPacketCount
			);
		} {
			if(~vmcMusicLastFrameComplete) {
				postf(
					"[VMC music] LIVE | raw bones:% | packets:% | /rokoko/ frames:%\n",
					~vmcMusicBones.size,
					~vmcMusicPacketCount,
					~vmcMusicFrameCount
				);
			} {
				postf(
					"[VMC music] RECEIVING | raw bones:% | waiting for:%\n",
					~vmcMusicBones.size,
					~vmcMusicMissingBones
				);
			};
		};
	};
};


// ---------------------------------------------------------------------------
// Start receiver and fixed-rate frame builder
// ---------------------------------------------------------------------------
~startVmcMusicRokoko = {
	OSCdef(\vmcMusicBone).free;

	if(~vmcMusicRoutine.notNil) {
		~vmcMusicRoutine.stop;
		~vmcMusicRoutine = nil;
	};

	~vmcMusicBones.clear;
	~vmcMusicLatestFrame = nil;
	~vmcMusicMissingBones = [];
	~vmcMusicDirty = false;
	~vmcMusicPacketCount = 0;
	~vmcMusicFrameCount = 0;
	~vmcMusicLastPacketTime = -1.0;
	~vmcMusicLastStatusTime = Main.elapsedTime;
	~vmcMusicLastFrameComplete = false;

	thisProcess.openUDPPort(~vmcMusicListenPort);

	OSCdef(
		\vmcMusicBone,
		{ |msg, time, sender, receivePort|
			var boneName, values;

			if(msg.size >= 9) {
				boneName = msg[1].asSymbol;
				values = msg[2..8].collect { |value| value.asFloat };

				// Raw copy: [x, y, z, qx, qy, qz, qw].
				~vmcMusicBones[boneName] = values;
				~vmcMusicPacketCount = ~vmcMusicPacketCount + 1;
				~vmcMusicLastPacketTime = Main.elapsedTime;
				~vmcMusicDirty = true;

				~onVmcMusicBone.value(boneName, values.copy);
			};
		},
		'/VMC/Ext/Bone/Pos',
		recvPort: ~vmcMusicListenPort
	);

	~vmcMusicRoutine = Routine({
		loop {
			if(~vmcMusicDirty) {
				~vmcMusicDirty = false;
				~vmcMusicMakeRokokoFrame.value;
			};

			if(
				(Main.elapsedTime - ~vmcMusicLastStatusTime)
				>= ~vmcMusicStatusInterval
			) {
				~vmcMusicLastStatusTime = Main.elapsedTime;
				~vmcMusicPostStatus.value;
			};

			(1.0 / ~vmcMusicFrameRate).wait;
		};
	}).play(SystemClock);

	postf(
		"[VMC music] Receiver started on UDP % | output: local /rokoko/\n",
		~vmcMusicListenPort
	);
};


// ---------------------------------------------------------------------------
// Optional connection to the existing sc-dance Avatar.
// This prepares sc-dance to consume the locally emitted /rokoko/ frames.
// It does NOT forward them to Godot.
// ---------------------------------------------------------------------------
~enableVmcMusicScDance = {
	Avatar.stop;
	Avatar.enableRemote('/rokoko/');
	Avatar.valuesGui;
	"[VMC music] sc-dance Avatar is listening to local /rokoko/.".postln;
};


// ---------------------------------------------------------------------------
// Stop safely
// ---------------------------------------------------------------------------
~stopVmcMusicRokoko = {
	OSCdef(\vmcMusicBone).free;

	if(~vmcMusicRoutine.notNil) {
		~vmcMusicRoutine.stop;
		~vmcMusicRoutine = nil;
	};

	"[VMC music] Receiver stopped.".postln;
};


// Start immediately after the whole parenthesized block is evaluated.
~startVmcMusicRokoko.value;

"[VMC music] Raw data example: ~vmcMusicBones[\\Head]".postln;
"[VMC music] Complete frame:  ~vmcMusicLatestFrame".postln;
"[VMC music] sc-dance input:  ~enableVmcMusicScDance.value;".postln;

)


// ============================================================================
// OPTIONAL EXAMPLES -- evaluate separately
// ============================================================================

// Print only the Head values: [x, y, z, qx, qy, qz, qw]
// ~onVmcMusicBone = { |bone, values|
//     if(bone == \Head) { values.postln };
// };

// Inspect selected raw values once per completed frame.
// ~onVmcMusicFrame = { |frame|
//     var head, leftHand, rightHand;
//     head = ~vmcMusicBones[\Head];
//     leftHand = ~vmcMusicBones[\LeftHand];
//     rightHand = ~vmcMusicBones[\RightHand];
//     [\head, head, \leftHand, leftHand, \rightHand, rightHand].postln;
// };

// Silence both callbacks again.
// ~onVmcMusicBone = { |bone, values| };
// ~onVmcMusicFrame = { |frame| };
