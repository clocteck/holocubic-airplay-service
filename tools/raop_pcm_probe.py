#!/usr/bin/env python3
# Author: sunfang1cn@gmail.com
"""Send an unencrypted RAOP protocol/audio probe to airplay_service.

This is deliberately a protocol probe, not an AirPlay implementation.  It
validates RTSP framing, transport negotiation, DMAP metadata and the RTP/I2S
PCM path independently of the native RSA/ALAC sender implementation.
"""

from __future__ import annotations

import argparse
import math
import random
import shutil
import socket
import struct
import subprocess
import threading
import time
import wave
from collections import deque
from pathlib import Path
from dataclasses import dataclass


@dataclass
class RtspResponse:
    code: int
    reason: str
    headers: dict[str, str]
    body: bytes


class RtspClient:
    def __init__(self, host: str, port: int, timeout: float) -> None:
        self.host = host
        self.port = port
        self.socket = socket.create_connection((host, port), timeout=timeout)
        self.socket.settimeout(timeout)
        self.cseq = 0
        self.session: str | None = None
        self.pending = bytearray()

    def close(self) -> None:
        self.socket.close()

    def request(
        self,
        method: str,
        uri: str = "*",
        *,
        headers: dict[str, str] | None = None,
        body: bytes = b"",
        expected: int = 200,
    ) -> RtspResponse:
        self.cseq += 1
        request_headers = {
            "CSeq": str(self.cseq),
            "User-Agent": "HoloCubic-RAOP-Probe/0.1",
        }
        if self.session:
            request_headers["Session"] = self.session
        if headers:
            request_headers.update(headers)
        if body:
            request_headers["Content-Length"] = str(len(body))

        lines = [f"{method} {uri} RTSP/1.0"]
        lines.extend(f"{key}: {value}" for key, value in request_headers.items())
        wire = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + body
        self.socket.sendall(wire)
        response = self._read_response()
        if response.code != expected:
            error = response.headers.get("x-airplay-error", "")
            raise RuntimeError(
                f"{method} returned {response.code} {response.reason} {error}".rstrip()
            )
        if response.headers.get("session"):
            self.session = response.headers["session"].split(";", 1)[0]
        return response

    def _read_response(self) -> RtspResponse:
        marker = b"\r\n\r\n"
        while marker not in self.pending:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise ConnectionError("RTSP socket closed while reading headers")
            self.pending.extend(chunk)
        head, remainder = bytes(self.pending).split(marker, 1)
        lines = head.decode("iso-8859-1").split("\r\n")
        protocol, code, reason = lines[0].split(" ", 2)
        if protocol != "RTSP/1.0":
            raise RuntimeError(f"unexpected RTSP protocol: {protocol}")
        headers: dict[str, str] = {}
        for line in lines[1:]:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        self.pending = bytearray(remainder)
        while len(self.pending) < length:
            chunk = self.socket.recv(4096)
            if not chunk:
                raise ConnectionError("RTSP socket closed while reading body")
            self.pending.extend(chunk)
        body = bytes(self.pending[:length])
        del self.pending[:length]
        return RtspResponse(int(code), reason, headers, body)

    def pipeline_options(self, count: int) -> None:
        requests: list[bytes] = []
        expected_cseq: list[str] = []
        for _ in range(count):
            self.cseq += 1
            cseq = str(self.cseq)
            expected_cseq.append(cseq)
            headers = [
                "OPTIONS * RTSP/1.0",
                f"CSeq: {cseq}",
                "User-Agent: HoloCubic-RAOP-Probe/0.1",
            ]
            if self.session:
                headers.append(f"Session: {self.session}")
            requests.append(("\r\n".join(headers) + "\r\n\r\n").encode("ascii"))
        self.socket.sendall(b"".join(requests))
        for cseq in expected_cseq:
            response = self._read_response()
            if response.code != 200 or response.headers.get("cseq") != cseq:
                raise RuntimeError(
                    "pipelined OPTIONS response mismatch: "
                    f"expected CSeq {cseq}, got {response.code} "
                    f"CSeq {response.headers.get('cseq')}"
                )


def ntp_timestamp() -> bytes:
    value = time.time() + 2_208_988_800
    seconds = int(value)
    fraction = int((value - seconds) * 2**32)
    return struct.pack(">II", seconds & 0xFFFFFFFF, fraction & 0xFFFFFFFF)


class TimingResponder:
    def __init__(self, udp: socket.socket) -> None:
        self.udp = udp
        self.requests = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.udp.settimeout(0.2)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                packet, peer = self.udp.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(packet) < 32 or packet[1] not in (0xD2, 0x52):
                continue
            stamp = ntp_timestamp()
            response = (
                bytes((0x80, 0xD3))
                + packet[2:4]
                + bytes(4)
                + packet[24:32]
                + stamp
                + stamp
            )
            try:
                self.udp.sendto(response, peer)
                self.requests += 1
            except OSError:
                return


class ResendResponder:
    """Keep recent RTP packets and answer AirPlay D5 requests with D6 packets."""

    def __init__(
        self,
        udp: socket.socket,
        history_packets: int = 2048,
        respond: bool = True,
        delay_ms: int = 0,
    ) -> None:
        self.udp = udp
        self.history_packets = history_packets
        self.respond = respond
        self.delay_ms = delay_ms
        self.requests = 0
        self.packets_requested = 0
        self.packets_sent = 0
        self.packets_missing = 0
        self._packets: dict[int, bytes] = {}
        self._order: deque[int] = deque()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.udp.settimeout(0.2)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)

    def remember(self, packet: bytes) -> None:
        if len(packet) < 12:
            return
        sequence = struct.unpack_from(">H", packet, 2)[0]
        with self._lock:
            if sequence not in self._packets:
                self._order.append(sequence)
            self._packets[sequence] = packet
            while len(self._order) > self.history_packets:
                expired = self._order.popleft()
                self._packets.pop(expired, None)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                packet, peer = self.udp.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(packet) < 8 or (packet[1] & 0x7F) != 0x55:
                continue
            first, count = struct.unpack_from(">HH", packet, 4)
            count = min(count, 256)
            self.requests += 1
            self.packets_requested += count
            if not self.respond:
                continue
            if self.delay_ms:
                time.sleep(self.delay_ms / 1000.0)
            for offset in range(count):
                sequence = (first + offset) & 0xFFFF
                with self._lock:
                    original = self._packets.get(sequence)
                if original is None:
                    self.packets_missing += 1
                    continue
                response = bytes((0x80, 0xD6)) + packet[2:4] + original
                try:
                    self.udp.sendto(response, peer)
                    self.packets_sent += 1
                except OSError:
                    return
            if len(packet) < 32 or packet[1] not in (0x52, 0xD2):
                continue
            stamp = ntp_timestamp()
            response = (
                bytes((0x80, 0xD3))
                + packet[2:4]
                + b"\0\0\0\0"
                + packet[24:32]
                + stamp
                + stamp
            )
            try:
                self.udp.sendto(response, peer)
                self.requests += 1
            except OSError:
                return


def dmap_tag(name: str, value: bytes) -> bytes:
    if len(name) != 4:
        raise ValueError("DMAP tags must contain four characters")
    return name.encode("ascii") + struct.pack(">I", len(value)) + value


def metadata(title: str, artist: str, album: str) -> bytes:
    item = b"".join(
        (
            dmap_tag("minm", title.encode("utf-8")),
            dmap_tag("asar", artist.encode("utf-8")),
            dmap_tag("asal", album.encode("utf-8")),
        )
    )
    return dmap_tag("mlit", item)


def parse_server_audio_port(transport: str) -> int:
    for item in transport.split(";"):
        key, separator, value = item.partition("=")
        if separator and key.strip().lower() == "server_port":
            return int(value)
    raise RuntimeError(f"SETUP response has no server_port: {transport}")


def wav_payload(reader: wave.Wave_read, frames_per_packet: int, loop: bool) -> bytes:
    frames = reader.readframes(frames_per_packet)
    frame_width = reader.getnchannels() * reader.getsampwidth()
    wanted = frames_per_packet * frame_width
    if len(frames) < wanted and loop:
        reader.rewind()
        frames += reader.readframes((wanted - len(frames)) // frame_width)
    if len(frames) < wanted:
        frames += bytes(wanted - len(frames))
    if reader.getnchannels() == 1:
        output = bytearray()
        for (sample,) in struct.iter_unpack("<h", frames):
            output.extend(struct.pack(">hh", sample, sample))
        return bytes(output)
    output = bytearray(len(frames))
    for offset in range(0, len(frames), 2):
        output[offset] = frames[offset + 1]
        output[offset + 1] = frames[offset]
    return bytes(output)


def synthetic_payload(
    packet_index: int,
    frames_per_packet: int,
    sample_rate: int,
    frequency: float,
    amplitude: float,
    signal: str,
) -> bytes:
    payload = bytearray()
    base_frame = packet_index * frames_per_packet
    for frame in range(frames_per_packet):
        sample_index = base_frame + frame
        phase = 2 * math.pi * frequency * sample_index / sample_rate
        if signal == "vocal":
            envelope = 0.55 + 0.45 * math.sin(2 * math.pi * 3.7 * sample_index / sample_rate)
            value = envelope * (
                0.52 * math.sin(phase)
                + 0.25 * math.sin(2 * phase)
                + 0.15 * math.sin(3 * phase)
                + 0.08 * math.sin(5 * phase)
            )
        else:
            value = math.sin(phase)
        sample = int(max(-1.0, min(1.0, value * amplitude)) * 32767)
        payload.extend(struct.pack(">hh", sample, sample))
    return bytes(payload)


def resolve_ffmpeg(configured: Path | None) -> Path:
    candidates = (
        [configured]
        if configured is not None
        else [
            Path(found) if (found := shutil.which("ffmpeg")) else None,
            Path(r"C:\Program Files\iGameCenter\SAVIConverter\tools\ffmpeg.exe"),
            Path(r"C:\Program Files (x86)\iGameZone II\SAVIConverter\tools\ffmpeg.exe"),
        ]
    )
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    raise RuntimeError("FFmpeg was not found; pass --ffmpeg PATH")


def read_pcm_pipe(decoder: subprocess.Popen[bytes], wanted: int) -> bytes:
    if decoder.stdout is None:
        raise RuntimeError("FFmpeg PCM pipe is unavailable")
    chunks: list[bytes] = []
    received = 0
    while received < wanted:
        chunk = decoder.stdout.read(wanted - received)
        if not chunk:
            break
        chunks.append(chunk)
        received += len(chunk)
    payload = b"".join(chunks)
    return payload + bytes(wanted - len(payload))


def send_pcm(
    udp: socket.socket,
    resend_responder: ResendResponder,
    target: tuple[str, int],
    *,
    duration: float,
    frequency: float,
    amplitude: float,
    signal: str,
    wav_path: Path | None,
    audio_path: Path | None,
    ffmpeg_path: Path | None,
    loop_wav: bool,
    drop_every: int,
    drop_burst_every: int,
    drop_burst_packets: int,
) -> tuple[int, int]:
    sequence = random.randrange(0, 65536)
    timestamp = random.randrange(0, 2**32)
    ssrc = random.randrange(0, 2**32)
    sample_rate = 44100
    frames_per_packet = 352
    packet_duration = frames_per_packet / sample_rate
    packet_count = max(1, math.ceil(duration / packet_duration))
    start = time.perf_counter()
    dropped = 0
    reader: wave.Wave_read | None = None
    decoder: subprocess.Popen[bytes] | None = None

    if audio_path is not None:
        ffmpeg = resolve_ffmpeg(ffmpeg_path)
        decoder = subprocess.Popen(
            [
                str(ffmpeg),
                "-v",
                "error",
                "-nostdin",
                "-i",
                str(audio_path),
                "-f",
                "s16be",
                "-acodec",
                "pcm_s16be",
                "-ar",
                str(sample_rate),
                "-ac",
                "2",
                "pipe:1",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    elif wav_path is not None:
        reader = wave.open(str(wav_path), "rb")
        if reader.getframerate() != sample_rate:
            reader.close()
            raise ValueError("WAV sample rate must be 44100 Hz")
        if reader.getsampwidth() != 2 or reader.getnchannels() not in (1, 2):
            reader.close()
            raise ValueError("WAV must be 16-bit PCM mono or stereo")

    try:
        for packet_index in range(packet_count):
            if decoder is not None:
                payload = read_pcm_pipe(decoder, frames_per_packet * 4)
            elif reader is not None:
                payload = wav_payload(reader, frames_per_packet, loop_wav)
            else:
                payload = synthetic_payload(
                    packet_index,
                    frames_per_packet,
                    sample_rate,
                    frequency,
                    amplitude,
                    signal,
                )
            header = struct.pack(
                ">BBHII",
                0x80,
                0x60,
                sequence,
                timestamp,
                ssrc,
            )
            packet = header + payload
            resend_responder.remember(packet)
            in_burst = (
                drop_burst_every > 0
                and packet_index >= drop_burst_every
                and packet_index % drop_burst_every < drop_burst_packets
            )
            drop = in_burst or (drop_every > 0 and packet_index > 0 and packet_index % drop_every == 0)
            if drop:
                dropped += 1
            else:
                udp.sendto(packet, target)
            sequence = (sequence + 1) & 0xFFFF
            timestamp = (timestamp + frames_per_packet) & 0xFFFFFFFF
            deadline = start + (packet_index + 1) * packet_duration
            remaining = deadline - time.perf_counter()
            if remaining > 0:
                time.sleep(remaining)
    finally:
        if reader is not None:
            reader.close()
        if decoder is not None:
            if decoder.stdout is not None:
                decoder.stdout.close()
            if decoder.poll() is None:
                decoder.terminate()
            try:
                decoder.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                decoder.kill()
                decoder.wait(timeout=2.0)
    return packet_count, dropped


def run(args: argparse.Namespace) -> None:
    control = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    timing = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    control.bind(("0.0.0.0", 0))
    timing.bind(("0.0.0.0", 0))
    control_port = control.getsockname()[1]
    timing_port = timing.getsockname()[1]
    timing_responder = TimingResponder(timing)
    timing_responder.start()
    resend_responder = ResendResponder(
        control,
        respond=not args.ignore_resend,
        delay_ms=args.resend_delay_ms,
    )
    resend_responder.start()
    rtsp = RtspClient(args.host, args.port, args.timeout)
    uri = f"rtsp://{args.host}/{random.randrange(1, 2**31)}"

    try:
        print("OPTIONS")
        rtsp.request("OPTIONS")

        codec_lines = (
            "a=rtpmap:96 AppleLossless/44100/2\r\n"
            "a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r\n"
            if args.codec == "alac"
            else "a=rtpmap:96 L16/44100/2\r\n"
        )
        sdp = (
            "v=0\r\n"
            "o=HoloCubicProbe 1 0 IN IP4 127.0.0.1\r\n"
            "s=HoloCubic PCM probe\r\n"
            "c=IN IP4 0.0.0.0\r\n"
            "t=0 0\r\n"
            "m=audio 0 RTP/AVP 96\r\n"
            + codec_lines
        ).encode("ascii")
        print(f"ANNOUNCE {args.codec.upper()}/44100/2")
        rtsp.request(
            "ANNOUNCE",
            uri,
            headers={"Content-Type": "application/sdp"},
            body=sdp,
        )

        print(f"SETUP control={control_port} timing={timing_port}")
        setup = rtsp.request(
            "SETUP",
            uri,
            headers={
                "Transport": (
                    "RTP/AVP/UDP;unicast;mode=record;"
                    f"control_port={control_port};timing_port={timing_port}"
                )
            },
        )
        audio_port = parse_server_audio_port(setup.headers["transport"])

        tagged = metadata(args.title, args.artist, args.album)
        print("SET_PARAMETER metadata")
        rtsp.request(
            "SET_PARAMETER",
            uri,
            headers={"Content-Type": "application/x-dmap-tagged"},
            body=tagged,
        )
        rtsp.request(
            "SET_PARAMETER",
            uri,
            headers={"Content-Type": "text/parameters"},
            body=b"volume: -12.0\r\n",
        )

        print(f"RECORD -> UDP {args.host}:{audio_port}")
        rtsp.request("RECORD", uri, headers={"Range": "npt=0-"})
        if args.pipeline_options:
            print(f"pipelined OPTIONS x{args.pipeline_options}")
            rtsp.pipeline_options(args.pipeline_options)
        if args.handshake_only:
            for index in range(args.metadata_updates):
                rtsp.request(
                    "SET_PARAMETER",
                    uri,
                    headers={"Content-Type": "application/x-dmap-tagged"},
                    body=metadata(
                        f"{args.title} {index + 1}", args.artist, args.album
                    ),
                )
                if args.metadata_interval > 0:
                    time.sleep(args.metadata_interval)
            time.sleep(args.hold_after_record)
            print(f"timing requests handled: {timing_responder.requests}")
            if args.require_timing and timing_responder.requests == 0:
                raise RuntimeError("receiver sent no AirPlay timing requests")
            if args.hold_after_record > 1:
                print("OPTIONS after idle hold")
                rtsp.request("OPTIONS")
        else:
            if args.codec != "l16":
                raise RuntimeError("ALAC probe currently supports --handshake-only only")
            packets, dropped = send_pcm(
                control,
                resend_responder,
                (args.host, audio_port),
                duration=args.duration,
                frequency=args.frequency,
                amplitude=args.amplitude,
                signal=args.signal,
                wav_path=args.wav,
                audio_path=args.audio_file,
                ffmpeg_path=args.ffmpeg,
                loop_wav=args.loop_wav,
                drop_every=args.drop_every,
                drop_burst_every=args.drop_burst_every,
                drop_burst_packets=args.drop_burst_packets,
            )
            time.sleep(0.25)
            print(f"generated {packets} RTP packets, intentionally dropped {dropped}")
            print(
                "resend requests "
                f"{resend_responder.requests}, requested {resend_responder.packets_requested}, "
                f"returned {resend_responder.packets_sent}, history misses "
                f"{resend_responder.packets_missing}"
            )
        rtsp.request("TEARDOWN", uri)
        print("PASS")
    finally:
        rtsp.close()
        resend_responder.stop()
        control.close()
        timing_responder.stop()
        timing.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="HoloCubic IPv4 address")
    parser.add_argument("--port", type=int, default=5000, help="RTSP port")
    parser.add_argument("--duration", type=float, default=3.0, help="tone duration")
    parser.add_argument("--frequency", type=float, default=440.0, help="tone frequency")
    parser.add_argument("--amplitude", type=float, default=0.2, help="0.0 to 1.0")
    parser.add_argument("--signal", choices=("sine", "vocal"), default="sine")
    parser.add_argument("--wav", type=Path, help="16-bit 44.1 kHz mono/stereo WAV")
    parser.add_argument("--audio-file", type=Path, help="audio file decoded to PCM through FFmpeg")
    parser.add_argument("--ffmpeg", type=Path, help="FFmpeg executable used with --audio-file")
    parser.add_argument("--loop-wav", action="store_true")
    parser.add_argument("--drop-every", type=int, default=0, help="drop every Nth original RTP packet")
    parser.add_argument("--drop-burst-every", type=int, default=0, help="start a loss burst every N packets")
    parser.add_argument("--drop-burst-packets", type=int, default=0, help="packets to drop in each burst")
    parser.add_argument("--ignore-resend", action="store_true", help="observe D5 requests without returning D6 packets")
    parser.add_argument("--resend-delay-ms", type=int, default=0, help="delay each D6 response batch")
    parser.add_argument("--timeout", type=float, default=5.0, help="socket timeout")
    parser.add_argument("--codec", choices=("l16", "alac"), default="l16")
    parser.add_argument("--handshake-only", action="store_true")
    parser.add_argument("--hold-after-record", type=float, default=0.2)
    parser.add_argument("--require-timing", action="store_true")
    parser.add_argument("--pipeline-options", type=int, default=0)
    parser.add_argument(
        "--metadata-updates",
        type=int,
        default=0,
        help="send repeated DMAP title updates after RECORD",
    )
    parser.add_argument(
        "--metadata-interval",
        type=float,
        default=0.05,
        help="seconds between repeated metadata updates",
    )
    parser.add_argument("--title", default="RAOP PCM Probe")
    parser.add_argument("--artist", default="HoloCubic")
    parser.add_argument("--album", default="AirPlay Service Test")
    args = parser.parse_args()
    if not 0 <= args.amplitude <= 1:
        parser.error("--amplitude must be between 0 and 1")
    if args.pipeline_options < 0:
        parser.error("--pipeline-options must be non-negative")
    if args.metadata_updates < 0 or args.metadata_interval < 0:
        parser.error("metadata update controls must be non-negative")
    if args.duration <= 0:
        parser.error("--duration must be positive")
    if args.drop_every < 0 or args.drop_burst_every < 0 or args.drop_burst_packets < 0:
        parser.error("drop controls must be non-negative")
    if args.resend_delay_ms < 0:
        parser.error("--resend-delay-ms must be non-negative")
    if args.drop_burst_packets and not args.drop_burst_every:
        parser.error("--drop-burst-packets requires --drop-burst-every")
    if args.wav and not args.wav.is_file():
        parser.error(f"WAV file not found: {args.wav}")
    if args.audio_file and not args.audio_file.is_file():
        parser.error(f"audio file not found: {args.audio_file}")
    if args.wav and args.audio_file:
        parser.error("--wav and --audio-file are mutually exclusive")
    if args.ffmpeg and not args.ffmpeg.is_file():
        parser.error(f"FFmpeg executable not found: {args.ffmpeg}")
    run(args)


if __name__ == "__main__":
    main()
