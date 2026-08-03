#!/usr/bin/env python3
"""Split large VMC/OSC bundles before sending them through OSCGroups.

Default route (laptop side):

    XR Animator  ->  127.0.0.1:39538
    this bridge  ->  127.0.0.1:22244  ->  OSCGroups

The bridge does not decode or alter VMC addresses, bone names, or values. Small
OSC packets are forwarded byte-for-byte. Oversized OSC bundles are separated
into smaller, valid OSC bundles while preserving every contained OSC message.

No third-party Python packages are required.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from dataclasses import dataclass
from typing import List, Sequence, Tuple


OSC_BUNDLE_PREFIX = b"#bundle\x00"
OSC_IMMEDIATE_TIMETAG = b"\x00\x00\x00\x00\x00\x00\x00\x01"
MAX_UDP_PAYLOAD = 65_507


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
        f"dropped={stats.dropped_packets}"
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

    print("VMC -> OSCGroups bundle-splitting bridge")
    print(f"  XR Animator sends to : {args.listen_ip}:{args.listen_port}")
    print(f"  Bridge forwards to   : {args.target_ip}:{args.target_port}")
    print(f"  Maximum OSC packet   : {args.max_packet_size} bytes")
    print("  Press Ctrl+C to stop.")

    last_stats_time = time.monotonic()

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
                    outgoing_packets = split_osc_packet(packet, args.max_packet_size)
                except OSCBundleError as exc:
                    stats.dropped_packets += 1
                    print(
                        f"WARNING: dropped {len(packet)}-byte packet: {exc}",
                        file=sys.stderr,
                    )
                    outgoing_packets = []

                if len(outgoing_packets) > 1:
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

    print(
        "Self-test passed: "
        f"{len(original_bundle)}-byte bundle -> {len(split_packets)} packets, "
        f"all <= {max_packet_size} bytes."
    )
    return 0


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Split oversized VMC/OSC bundles into Internet-safe packets and "
            "forward them to OSCGroups. No third-party packages are required."
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


def main() -> int:
    parser = build_argument_parser()
    args = parser.parse_args()
    _validate_arguments(parser, args)

    if args.self_test:
        return run_self_test(args.max_packet_size)
    return run_bridge(args)


if __name__ == "__main__":
    raise SystemExit(main())
