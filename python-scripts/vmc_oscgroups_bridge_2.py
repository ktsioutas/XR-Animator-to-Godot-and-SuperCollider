#!/usr/bin/env python3
"""Translate XR Animator facial presets and split VMC/OSC bundles.

Default route (laptop side):

    XR Animator  ->  127.0.0.1:39538
    this bridge  ->  127.0.0.1:22244  ->  OSCGroups

The bridge preserves every original VMC message. It additionally translates
XR Animator's short VRM facial preset names (for example ``blink_l`` and
``joy``) into the ARKit-style names accepted by GodotXRVmcTracker. Oversized
OSC bundles are separated into smaller, valid bundles while preserving every
contained OSC message.

No third-party Python packages are required.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from dataclasses import dataclass
from typing import Dict, List, Sequence, Set, Tuple


OSC_BUNDLE_PREFIX = b"#bundle\x00"
OSC_IMMEDIATE_TIMETAG = b"\x00\x00\x00\x00\x00\x00\x00\x01"
MAX_UDP_PAYLOAD = 65_507
VMC_BLEND_VALUE_ADDRESS = "/VMC/Ext/Blend/Val"


# Keys are normalized with _normalize_face_name(), so matching is insensitive
# to capitalization, underscores, hyphens, and spaces. Targets use the exact
# case-sensitive names accepted by GodotXRVmcTracker.
FACE_ALIAS_TARGETS: Dict[str, Tuple[str, ...]] = {
    # Eyelids
    "blink": ("EyeBlinkLeft", "EyeBlinkRight"),
    "blinkl": ("EyeBlinkLeft",),
    "blinkleft": ("EyeBlinkLeft",),
    "blinkr": ("EyeBlinkRight",),
    "blinkright": ("EyeBlinkRight",),
    # VRM emotion presets
    "joy": ("MouthSmileLeft", "MouthSmileRight"),
    "happy": ("MouthSmileLeft", "MouthSmileRight"),
    "fun": ("MouthSmileLeft", "MouthSmileRight"),
    "sorrow": ("MouthFrownLeft", "MouthFrownRight"),
    "sad": ("MouthFrownLeft", "MouthFrownRight"),
    "angry": ("BrowDownLeft", "BrowDownRight"),
    # Eye-direction presets
    "lookup": ("EyeLookUpLeft", "EyeLookUpRight"),
    "lookdown": ("EyeLookDownLeft", "EyeLookDownRight"),
    "lookleft": ("EyeLookOutLeft", "EyeLookInRight"),
    "lookright": ("EyeLookInLeft", "EyeLookOutRight"),
    # VRM vowel presets. These are approximate ARKit equivalents, but they
    # allow Test-Kun's mouth to respond visibly to XR Animator mouth tracking.
    "a": ("JawOpen",),
    "aa": ("JawOpen",),
    "mouthopen": ("JawOpen",),
    "i": ("MouthStretchLeft", "MouthStretchRight"),
    "e": ("MouthStretchLeft", "MouthStretchRight"),
    "u": ("MouthPucker",),
    "o": ("MouthFunnel",),
}

CANONICAL_FACE_NAMES: Set[str] = {
    target
    for targets in FACE_ALIAS_TARGETS.values()
    for target in targets
}


class OSCBundleError(ValueError):
    """Raised when an OSC bundle is incomplete or structurally invalid."""


@dataclass
class BridgeStats:
    received_packets: int = 0
    received_bytes: int = 0
    sent_packets: int = 0
    sent_bytes: int = 0
    oversized_bundles: int = 0
    dropped_packets: int = 0
    face_blend_messages: int = 0
    generated_face_messages: int = 0


def _flatten_osc_element(
    element: bytes,
    parent_timetag: bytes,
) -> List[Tuple[bytes, bytes]]:
    """Return ordered (timetag, OSC message) leaves from an OSC element."""
    if element.startswith(OSC_BUNDLE_PREFIX):
        return _flatten_osc_bundle(element)
    if element.startswith(b"/"):
        return [(parent_timetag, element)]
    raise OSCBundleError("bundle element is neither an OSC message nor a bundle")


def _flatten_osc_bundle(packet: bytes) -> List[Tuple[bytes, bytes]]:
    """Recursively flatten an OSC bundle without interpreting message data."""
    if not packet.startswith(OSC_BUNDLE_PREFIX):
        raise OSCBundleError("packet does not start with the OSC bundle header")
    if len(packet) < 16:
        raise OSCBundleError("OSC bundle is shorter than its 16-byte header")

    timetag = packet[8:16]
    offset = 16
    messages: List[Tuple[bytes, bytes]] = []

    while offset < len(packet):
        if offset + 4 > len(packet):
            raise OSCBundleError("truncated OSC bundle-element size")

        element_size = struct.unpack_from(">I", packet, offset)[0]
        offset += 4

        if element_size == 0:
            raise OSCBundleError("OSC bundle contains an empty element")

        element_end = offset + element_size
        if element_end > len(packet):
            raise OSCBundleError("OSC bundle element extends past the packet")

        element = packet[offset:element_end]
        messages.extend(_flatten_osc_element(element, timetag))
        offset = element_end

    return messages


def _build_osc_bundle(timetag: bytes, messages: Sequence[bytes]) -> bytes:
    if len(timetag) != 8:
        raise OSCBundleError("an OSC timetag must contain exactly 8 bytes")

    output = bytearray(OSC_BUNDLE_PREFIX)
    output.extend(timetag)
    for message in messages:
        output.extend(struct.pack(">I", len(message)))
        output.extend(message)
    return bytes(output)


def _read_osc_string(data: bytes, offset: int) -> Tuple[str, int]:
    """Read one null-terminated, four-byte-padded OSC string."""
    if offset < 0 or offset >= len(data):
        raise OSCBundleError("OSC string begins outside the message")

    end = data.find(b"\x00", offset)
    if end < 0:
        raise OSCBundleError("OSC string is not null terminated")

    try:
        value = data[offset:end].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise OSCBundleError("OSC string is not valid UTF-8") from exc

    next_offset = (end + 4) & ~3
    if next_offset > len(data):
        raise OSCBundleError("OSC string padding extends past the message")
    return value, next_offset


def _parse_face_blend_message(message: bytes) -> Tuple[str, float] | None:
    """Return (blend-name, value) for a VMC Blend/Val message."""
    if not message.startswith(b"/VMC/Ext/Blend/Val"):
        return None

    try:
        address, offset = _read_osc_string(message, 0)
        type_tags, offset = _read_osc_string(message, offset)
        if address != VMC_BLEND_VALUE_ADDRESS or type_tags != ",sf":
            return None
        blend_name, offset = _read_osc_string(message, offset)
        if offset + 4 > len(message):
            raise OSCBundleError("VMC face blend message has no float value")
        value = struct.unpack_from(">f", message, offset)[0]
    except OSCBundleError:
        return None

    return blend_name, value


def _make_face_blend_message(blend_name: str, value: float) -> bytes:
    return b"".join(
        (
            _padded_osc_string(VMC_BLEND_VALUE_ADDRESS),
            _padded_osc_string(",sf"),
            _padded_osc_string(blend_name),
            struct.pack(">f", float(value)),
        )
    )


def _normalize_face_name(name: str) -> str:
    return "".join(character for character in name.casefold() if character.isalnum())


def _build_bundles_from_leaves(
    leaves: Sequence[Tuple[bytes, bytes]],
) -> List[bytes]:
    """Build ordered bundles while preserving each leaf's OSC timetag."""
    packets: List[bytes] = []
    current_timetag: bytes | None = None
    current_messages: List[bytes] = []

    def flush() -> None:
        nonlocal current_timetag, current_messages
        if current_messages:
            assert current_timetag is not None
            packets.append(_build_osc_bundle(current_timetag, current_messages))
        current_timetag = None
        current_messages = []

    for timetag, message in leaves:
        if current_timetag is not None and timetag != current_timetag:
            flush()
        if current_timetag is None:
            current_timetag = timetag
        current_messages.append(message)

    flush()
    return packets


def translate_face_blends(
    packet: bytes,
) -> Tuple[List[bytes], Dict[str, float], Dict[str, float], int]:
    """Add ARKit-name aliases while preserving every original OSC message.

    Returns (packets, recognized-input-values, generated-output-values,
    face-message-count). Packets containing no recognized aliases are returned
    byte-for-byte. If a native ARKit target is present in the same packet, it
    wins and no generated alias is created for that target.
    """
    is_bundle = packet.startswith(OSC_BUNDLE_PREFIX)
    leaves = (
        _flatten_osc_bundle(packet)
        if is_bundle
        else [(OSC_IMMEDIATE_TIMETAG, packet)]
    )

    parsed_leaves: List[Tuple[bytes, str, float]] = []
    existing_canonical_names: Set[str] = set()
    face_message_count = 0

    for timetag, message in leaves:
        parsed = _parse_face_blend_message(message)
        if parsed is None:
            continue
        blend_name, value = parsed
        face_message_count += 1
        parsed_leaves.append((timetag, blend_name, value))
        if blend_name in CANONICAL_FACE_NAMES:
            existing_canonical_names.add(blend_name)

    input_values: Dict[str, float] = {}
    generated_values: Dict[str, float] = {}
    generated_timetags: Dict[str, bytes] = {}

    for timetag, blend_name, value in parsed_leaves:
        targets = FACE_ALIAS_TARGETS.get(_normalize_face_name(blend_name))
        if not targets:
            continue

        input_values[blend_name] = value
        alias_value = max(0.0, min(1.0, value))
        for target in targets:
            if target in existing_canonical_names:
                continue

            # More than one VRM preset may map to the same ARKit channel
            # (for example joy and fun). Use the strongest value in the frame.
            if (
                target not in generated_values
                or alias_value >= generated_values[target]
            ):
                generated_values[target] = alias_value
                generated_timetags[target] = timetag

    if not generated_values:
        return [packet], input_values, generated_values, face_message_count

    generated_leaves = [
        (
            generated_timetags[target],
            _make_face_blend_message(target, value),
        )
        for target, value in generated_values.items()
    ]

    if is_bundle:
        translated_packets = _build_bundles_from_leaves([*leaves, *generated_leaves])
    else:
        translated_packets = [packet, *(message for _timetag, message in generated_leaves)]

    return (
        translated_packets,
        input_values,
        generated_values,
        face_message_count,
    )


def split_osc_packet(packet: bytes, max_packet_size: int) -> List[bytes]:
    """Return one or more OSC packets, each no larger than max_packet_size.

    Packets already within the limit are returned unchanged. Only oversized
    bundles are split. A single oversized non-bundle OSC message cannot be
    split without changing its meaning and therefore raises OSCBundleError.
    """
    if len(packet) <= max_packet_size:
        return [packet]

    if not packet.startswith(OSC_BUNDLE_PREFIX):
        raise OSCBundleError(
            "oversized packet is not an OSC bundle and cannot be safely split"
        )

    leaves = _flatten_osc_bundle(packet)
    if not leaves:
        raise OSCBundleError("oversized OSC bundle contains no messages")

    output_packets: List[bytes] = []
    current_timetag: bytes | None = None
    current_messages: List[bytes] = []
    current_size = 16

    def flush() -> None:
        nonlocal current_timetag, current_messages, current_size
        if current_messages:
            assert current_timetag is not None
            output_packets.append(_build_osc_bundle(current_timetag, current_messages))
        current_timetag = None
        current_messages = []
        current_size = 16

    for timetag, message in leaves:
        bundled_message_size = 4 + len(message)
        if 16 + bundled_message_size > max_packet_size:
            raise OSCBundleError(
                f"one OSC message requires {16 + bundled_message_size} bytes, "
                f"exceeding the {max_packet_size}-byte limit"
            )

        if current_timetag is not None and timetag != current_timetag:
            flush()

        if current_messages and current_size + bundled_message_size > max_packet_size:
            flush()

        if current_timetag is None:
            current_timetag = timetag

        current_messages.append(message)
        current_size += bundled_message_size

    flush()

    if not output_packets:
        raise OSCBundleError("OSC bundle splitting produced no output packets")
    if any(len(item) > max_packet_size for item in output_packets):
        raise OSCBundleError("internal error: a split packet exceeds the size limit")

    return output_packets


def _format_stats(stats: BridgeStats) -> str:
    return (
        f"received={stats.received_packets} packets, "
        f"split={stats.oversized_bundles}, "
        f"sent={stats.sent_packets}, "
        f"dropped={stats.dropped_packets}, "
        f"face_in={stats.face_blend_messages}, "
        f"face_aliases={stats.generated_face_messages}"
    )


def _format_face_values(
    input_values: Dict[str, float],
    generated_values: Dict[str, float],
) -> str:
    input_text = ", ".join(
        f"{name}={value:.3f}" for name, value in sorted(input_values.items())
    )
    output_text = ", ".join(
        f"{name}={value:.3f}" for name, value in sorted(generated_values.items())
    )
    return (
        f"[face] XR Animator [{input_text or 'none'}] "
        f"-> Godot aliases [{output_text or 'none'}]"
    )


def run_bridge(args: argparse.Namespace) -> int:
    stats = BridgeStats()
    receive_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    send_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    try:
        # A larger kernel queue helps absorb short bursts from XR Animator.
        receive_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        receive_socket.bind((args.listen_ip, args.listen_port))
        receive_socket.settimeout(0.5)
    except OSError as exc:
        receive_socket.close()
        send_socket.close()
        print(
            f"ERROR: cannot listen on {args.listen_ip}:{args.listen_port}: {exc}",
            file=sys.stderr,
        )
        print(
            "Check that no other program is using the bridge input port.",
            file=sys.stderr,
        )
        return 1

    print("VMC -> OSCGroups facial-translation and bundle-splitting bridge")
    print(f"  XR Animator sends to : {args.listen_ip}:{args.listen_port}")
    print(f"  Bridge forwards to   : {args.target_ip}:{args.target_port}")
    print(f"  Maximum OSC packet   : {args.max_packet_size} bytes")
    print(
        "  Facial translation   : "
        + ("OFF" if args.no_face_translation else "ON")
    )
    print("  Press Ctrl+C to stop.")

    last_stats_time = time.monotonic()
    last_face_log_time = time.monotonic()
    latest_face_inputs: Dict[str, float] = {}
    latest_face_outputs: Dict[str, float] = {}
    announced_face_inputs: Set[str] = set()
    face_log_dirty = False

    try:
        while True:
            try:
                packet, _sender = receive_socket.recvfrom(MAX_UDP_PAYLOAD)
            except socket.timeout:
                packet = b""

            if packet:
                stats.received_packets += 1
                stats.received_bytes += len(packet)

                try:
                    if args.no_face_translation:
                        translated_packets = [packet]
                        face_inputs: Dict[str, float] = {}
                        face_outputs: Dict[str, float] = {}
                        face_message_count = 0
                    else:
                        (
                            translated_packets,
                            face_inputs,
                            face_outputs,
                            face_message_count,
                        ) = translate_face_blends(packet)

                    stats.face_blend_messages += face_message_count
                    stats.generated_face_messages += len(face_outputs)

                    if face_inputs:
                        latest_face_inputs.update(face_inputs)
                        latest_face_outputs.update(face_outputs)
                        face_log_dirty = True

                        for source_name in face_inputs:
                            normalized = _normalize_face_name(source_name)
                            if normalized in announced_face_inputs:
                                continue
                            announced_face_inputs.add(normalized)
                            targets = FACE_ALIAS_TARGETS[normalized]
                            print(
                                f"[face] alias enabled: {source_name} -> "
                                + ", ".join(targets)
                            )

                    outgoing_packets: List[bytes] = []
                    packet_was_split = False
                    for translated_packet in translated_packets:
                        split_packets = split_osc_packet(
                            translated_packet,
                            args.max_packet_size,
                        )
                        if len(split_packets) > 1:
                            packet_was_split = True
                        outgoing_packets.extend(split_packets)
                except OSCBundleError as exc:
                    stats.dropped_packets += 1
                    print(
                        f"WARNING: dropped {len(packet)}-byte packet: {exc}",
                        file=sys.stderr,
                    )
                    outgoing_packets = []
                    packet_was_split = False

                if packet_was_split:
                    stats.oversized_bundles += 1

                for outgoing in outgoing_packets:
                    try:
                        send_socket.sendto(
                            outgoing,
                            (args.target_ip, args.target_port),
                        )
                    except OSError as exc:
                        stats.dropped_packets += 1
                        print(f"WARNING: UDP send failed: {exc}", file=sys.stderr)
                        continue

                    stats.sent_packets += 1
                    stats.sent_bytes += len(outgoing)

            now = time.monotonic()
            if (
                args.face_log_interval > 0
                and face_log_dirty
                and now - last_face_log_time >= args.face_log_interval
            ):
                print(_format_face_values(latest_face_inputs, latest_face_outputs))
                last_face_log_time = now
                face_log_dirty = False

            if args.stats_interval > 0 and now - last_stats_time >= args.stats_interval:
                print(_format_stats(stats))
                last_stats_time = now

    except KeyboardInterrupt:
        print("\nBridge stopped.")
        print(_format_stats(stats))
        return 0
    finally:
        receive_socket.close()
        send_socket.close()


def _padded_osc_string(value: str) -> bytes:
    encoded = value.encode("utf-8") + b"\x00"
    return encoded + (b"\x00" * ((-len(encoded)) % 4))


def _make_test_bone_message(index: int) -> bytes:
    return b"".join(
        (
            _padded_osc_string("/VMC/Ext/Bone/Pos"),
            _padded_osc_string(",sfffffff"),
            _padded_osc_string(f"TestBone{index:02d}"),
            struct.pack(">7f", *(float(index + offset) for offset in range(7))),
        )
    )


def run_self_test(max_packet_size: int) -> int:
    # Original bundle splitting must remain byte-for-byte lossless.
    original_messages = [_make_test_bone_message(index) for index in range(70)]
    original_bundle = _build_osc_bundle(OSC_IMMEDIATE_TIMETAG, original_messages)
    split_packets = split_osc_packet(original_bundle, max_packet_size)

    recovered_messages: List[bytes] = []
    for split_packet in split_packets:
        assert len(split_packet) <= max_packet_size
        recovered_messages.extend(
            message for _timetag, message in _flatten_osc_bundle(split_packet)
        )

    assert recovered_messages == original_messages
    assert split_osc_packet(b"/small\x00\x00", max_packet_size) == [b"/small\x00\x00"]

    # XR Animator's VRM preset names must produce the expected Godot aliases
    # while every original face message remains present.
    face_original_messages = [
        _make_face_blend_message("blink", 0.75),
        _make_face_blend_message("joy", 0.60),
        _make_face_blend_message("a", 0.40),
        _make_face_blend_message("lookLeft", 0.50),
    ]
    face_bundle = _build_osc_bundle(
        OSC_IMMEDIATE_TIMETAG,
        face_original_messages,
    )
    (
        translated_face_packets,
        face_inputs,
        face_outputs,
        face_message_count,
    ) = translate_face_blends(face_bundle)

    assert face_message_count == len(face_original_messages)
    expected_face_inputs = {
        "blink": 0.75,
        "joy": 0.60,
        "a": 0.40,
        "lookLeft": 0.50,
    }
    expected_face_outputs = {
        "EyeBlinkLeft": 0.75,
        "EyeBlinkRight": 0.75,
        "MouthSmileLeft": 0.60,
        "MouthSmileRight": 0.60,
        "JawOpen": 0.40,
        "EyeLookOutLeft": 0.50,
        "EyeLookInRight": 0.50,
    }
    assert face_inputs.keys() == expected_face_inputs.keys()
    for name, expected_value in expected_face_inputs.items():
        assert abs(face_inputs[name] - expected_value) < 0.000_001
    assert face_outputs.keys() == expected_face_outputs.keys()
    for name, expected_value in expected_face_outputs.items():
        assert abs(face_outputs[name] - expected_value) < 0.000_001

    forwarded_face_packets: List[bytes] = []
    for translated_packet in translated_face_packets:
        forwarded_face_packets.extend(
            split_osc_packet(translated_packet, max_packet_size)
        )

    recovered_face_messages: List[bytes] = []
    for forwarded_packet in forwarded_face_packets:
        assert len(forwarded_packet) <= max_packet_size
        if forwarded_packet.startswith(OSC_BUNDLE_PREFIX):
            recovered_face_messages.extend(
                message
                for _timetag, message in _flatten_osc_bundle(forwarded_packet)
            )
        else:
            recovered_face_messages.append(forwarded_packet)

    for original_message in face_original_messages:
        assert original_message in recovered_face_messages

    recovered_face_values = {
        parsed[0]: parsed[1]
        for message in recovered_face_messages
        if (parsed := _parse_face_blend_message(message)) is not None
    }
    for name, expected_value in expected_face_outputs.items():
        assert abs(recovered_face_values[name] - expected_value) < 0.000_001

    # A native ARKit value in a frame takes priority over a generated alias.
    native_smile = _make_face_blend_message("MouthSmileLeft", 0.90)
    priority_bundle = _build_osc_bundle(
        OSC_IMMEDIATE_TIMETAG,
        [native_smile, _make_face_blend_message("joy", 0.25)],
    )
    _packets, _inputs, priority_outputs, _count = translate_face_blends(
        priority_bundle
    )
    assert "MouthSmileLeft" not in priority_outputs
    assert abs(priority_outputs["MouthSmileRight"] - 0.25) < 0.000_001

    print(
        "Self-test passed: "
        f"{len(original_bundle)}-byte bundle -> {len(split_packets)} packets, "
        f"all <= {max_packet_size} bytes; facial aliases preserved and verified."
    )
    return 0


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Translate XR Animator VRM facial presets to Godot-compatible "
            "ARKit names, split oversized VMC/OSC bundles into Internet-safe "
            "packets, and forward them to OSCGroups. No third-party packages "
            "are required."
        )
    )
    parser.add_argument(
        "--listen-ip",
        default="127.0.0.1",
        help="IP on which the bridge receives XR Animator VMC (default: %(default)s)",
    )
    parser.add_argument(
        "--listen-port",
        type=int,
        default=39538,
        help="port on which the bridge receives XR Animator VMC (default: %(default)s)",
    )
    parser.add_argument(
        "--target-ip",
        default="127.0.0.1",
        help="OSCGroups client IP (default: %(default)s)",
    )
    parser.add_argument(
        "--target-port",
        type=int,
        default=22244,
        help="OSCGroups localtx port (default: %(default)s)",
    )
    parser.add_argument(
        "--max-packet-size",
        type=int,
        default=1200,
        help="maximum forwarded UDP/OSC payload size (default: %(default)s)",
    )
    parser.add_argument(
        "--stats-interval",
        type=float,
        default=5.0,
        help="seconds between status lines; 0 disables them (default: %(default)s)",
    )
    parser.add_argument(
        "--face-log-interval",
        type=float,
        default=2.0,
        help=(
            "seconds between translated facial-value logs; 0 disables them "
            "(default: %(default)s)"
        ),
    )
    parser.add_argument(
        "--no-face-translation",
        action="store_true",
        help="disable VRM-to-ARKit facial aliases and use splitter-only mode",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="test OSC bundle splitting and exit",
    )
    return parser


def _validate_arguments(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    for name in ("listen_port", "target_port"):
        value = getattr(args, name)
        if not 1 <= value <= 65_535:
            parser.error(f"--{name.replace('_', '-')} must be between 1 and 65535")

    if not 128 <= args.max_packet_size <= MAX_UDP_PAYLOAD:
        parser.error(
            f"--max-packet-size must be between 128 and {MAX_UDP_PAYLOAD}"
        )
    if args.stats_interval < 0:
        parser.error("--stats-interval cannot be negative")
    if args.face_log_interval < 0:
        parser.error("--face-log-interval cannot be negative")


def main() -> int:
    parser = build_argument_parser()
    args = parser.parse_args()
    _validate_arguments(parser, args)

    if args.self_test:
        return run_self_test(args.max_packet_size)
    return run_bridge(args)


if __name__ == "__main__":
    raise SystemExit(main())
