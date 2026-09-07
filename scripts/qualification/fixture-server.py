#!/usr/bin/env python3
"""Deterministic HTTP media server with media faults and adaptive HLS telemetry."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_validation import atomic_write_json  # noqa: E402


class RangeNotSatisfiable(ValueError):
    pass


TIMEBASE_VOD_SECONDS = 14_400
ADAPTIVE_SEGMENT_SECONDS = 2
PROGRESSIVE_COMMAND_ORIGIN_HEADER = "X-SwiftVLC-Progressive-Command-Origin"
PROGRESSIVE_COMMAND_ORIGIN = "candidate-app-before-strict-request-seek-v1"


class FixtureHandler(BaseHTTPRequestHandler):
    server: "FixtureHTTPServer"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        started = time.monotonic()
        status = HTTPStatus.OK
        self.response_status = HTTPStatus.OK
        self.response_content_range: str | None = None
        transferred = 0
        progressive_request: dict | None = None
        self.progressive_transferred = 0
        self.progressive_completed = False
        try:
            route = unquote(urlsplit(self.path).path)
            if route == "/healthz":
                payload = json.dumps({"status": "ok"}).encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                transferred = len(payload)
                return

            match = re.fullmatch(r"/fault/trigger/([A-Za-z0-9._-]+)", route)
            if match:
                generation = self.server.trigger_stall(match.group(1))
                payload = json.dumps({"generation": generation}).encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                transferred = len(payload)
                return

            match = re.fullmatch(r"/fault/close-trigger/([A-Za-z0-9._-]+)", route)
            if match:
                generation = self.server.trigger_close(match.group(1))
                payload = json.dumps({"generation": generation}).encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                transferred = len(payload)
                return

            match = re.fullmatch(r"/fault/gated-close/([A-Za-z0-9._-]+)/(.+)", route)
            if match:
                token = match.group(1)
                if self.server.close_generation(token) > 0:
                    status = HTTPStatus.SERVICE_UNAVAILABLE
                    self.response_status = status
                    self.send_error(status, "fixture connection was closed")
                    return
                transferred = self._serve_loop(
                    self._safe_path(match.group(2)), close_token=token
                )
                return

            match = re.fullmatch(
                r"/fault/gated-stall/([A-Za-z0-9._-]+)/([0-9]+(?:\.[0-9]+)?)/(.+)",
                route,
            )
            if match:
                transferred = self._serve_loop(
                    self._safe_path(match.group(3)),
                    stall_token=match.group(1),
                    stall_seconds=float(match.group(2)),
                )
                return

            match = re.fullmatch(r"/adaptive/([A-Za-z0-9._-]+)/metrics", route)
            if match:
                payload = json.dumps(
                    self.server.adaptive_metrics(match.group(1)), sort_keys=True
                ).encode()
                transferred = self._serve_bytes(payload, "application/json")
                return

            match = re.fullmatch(r"/adaptive/([A-Za-z0-9._-]+)/complete", route)
            if match:
                payload = json.dumps(
                    self.server.complete_adaptive_run(match.group(1)), sort_keys=True
                ).encode()
                transferred = self._serve_bytes(payload, "application/json")
                return

            match = re.fullmatch(
                r"/progressive/([A-Za-z0-9._-]+)/(range|no-range)/command", route
            )
            if match:
                payload = json.dumps(
                    self.server.mark_progressive_command(
                        *match.groups(),
                        origin=self.headers.get(PROGRESSIVE_COMMAND_ORIGIN_HEADER),
                    ),
                    sort_keys=True,
                ).encode()
                transferred = self._serve_bytes(payload, "application/json")
                return

            match = re.fullmatch(r"/progressive/([A-Za-z0-9._-]+)/transcript", route)
            if match:
                payload = json.dumps(
                    self.server.progressive_transcript(match.group(1)),
                    sort_keys=True,
                ).encode()
                transferred = self._serve_bytes(payload, "application/json")
                return

            match = re.fullmatch(
                r"/progressive/([A-Za-z0-9._-]+)/(range|no-range)/media\.mp4",
                route,
            )
            if match:
                token, mode = match.groups()
                path = self._safe_path("oracles/progressive-range.mp4")
                progressive_request = self.server.begin_progressive_request(
                    token,
                    mode,
                    route,
                    self.headers.get("Range"),
                )
                transferred = self._serve_progressive_file(
                    path,
                    range_capable=mode == "range",
                    event=progressive_request,
                )
                self.progressive_completed = True
                return

            match = re.fullmatch(
                r"/adaptive/([A-Za-z0-9._-]+)/([a-z0-9-]+)/master\.m3u8",
                route,
            )
            if match:
                payload = self.server.adaptive_master(
                    match.group(1), match.group(2)
                ).encode()
                transferred = self._serve_bytes(
                    payload, "application/vnd.apple.mpegurl"
                )
                return

            match = re.fullmatch(
                r"/adaptive/([A-Za-z0-9._-]+)/([a-z0-9-]+)/(low|high)\.m3u8",
                route,
            )
            if match:
                payload = self.server.adaptive_media_playlist(
                    match.group(1), match.group(2), match.group(3)
                ).encode()
                transferred = self._serve_bytes(
                    payload, "application/vnd.apple.mpegurl"
                )
                return

            match = re.fullmatch(
                r"/adaptive/([A-Za-z0-9._-]+)/([a-z0-9-]+)/(low|high)/([A-Za-z0-9._-]+)",
                route,
            )
            if match:
                token, mode, variant, filename = match.groups()
                container = self.server.adaptive_container(mode)
                if self.server.should_fail_adaptive_asset(
                    token, mode, variant, filename
                ):
                    status = HTTPStatus.SERVICE_UNAVAILABLE
                    self.response_status = status
                    self.send_error(status, "deterministic adaptive retry")
                    return
                path = self._safe_path(f"hls/soak/{container}/{variant}/{filename}")
                transferred = self._serve_file(path)
                self.server.record_adaptive_asset(
                    token, mode, variant, filename, recovered=True
                )
                return

            match = re.fullmatch(r"/live/(.+)", route)
            if match:
                transferred = self._serve_loop(self._safe_path(match.group(1)))
                return

            match = re.fullmatch(r"/fault/stall/([0-9]+(?:\.[0-9]+)?)/(.+)", route)
            if match:
                transferred = self._serve_file(
                    self._safe_path(match.group(2)), stall_seconds=float(match.group(1))
                )
                return

            match = re.fullmatch(r"/fault/close/(\d+)/(.+)", route)
            if match:
                transferred = self._serve_file(
                    self._safe_path(match.group(2)), close_after=int(match.group(1))
                )
                return

            match = re.fullmatch(r"/fault/status/(\d{3})", route)
            if match:
                status = HTTPStatus(int(match.group(1)))
                self.response_status = status
                self.send_error(status)
                return

            match = re.fullmatch(r"/files/(.+)", route)
            if match:
                transferred = self._serve_file(self._safe_path(match.group(1)))
                return

            status = HTTPStatus.NOT_FOUND
            self.response_status = status
            self.send_error(status)
        except (BrokenPipeError, ConnectionResetError):
            if progressive_request is not None:
                transferred = self.progressive_transferred
            else:
                status = HTTPStatus.PARTIAL_CONTENT
                self.response_status = status
        except (FileNotFoundError, IsADirectoryError):
            status = HTTPStatus.NOT_FOUND
            self.response_status = status
            self.send_error(status)
        except ValueError as error:
            status = HTTPStatus.BAD_REQUEST
            self.response_status = status
            self.send_error(status, str(error))
        finally:
            status = self.response_status
            if progressive_request is not None:
                self.server.finish_progressive_request(
                    progressive_request,
                    response_status=int(status),
                    response_content_range=self.response_content_range,
                    accept_ranges=(
                        "bytes" if progressive_request["mode"] == "range" else None
                    ),
                    response_content_length=getattr(
                        self, "progressive_response_content_length", None
                    ),
                    transferred_bytes=self.progressive_transferred,
                    completed=self.progressive_completed,
                )
            self.server.record(
                {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "client": self.client_address[0],
                    "method": "GET",
                    "path": self.path,
                    "status": int(status),
                    "requestRange": self.headers.get("Range"),
                    "responseContentRange": self.response_content_range,
                    "bytes": transferred,
                    "durationSeconds": round(time.monotonic() - started, 6),
                }
            )

    def _safe_path(self, relative: str) -> Path:
        candidate = (self.server.root / relative).resolve()
        if candidate != self.server.root and self.server.root not in candidate.parents:
            raise ValueError("path escapes fixture root")
        if not candidate.is_file():
            raise FileNotFoundError(candidate)
        return candidate

    def _serve_bytes(self, payload: bytes, content_type: str) -> int:
        self.response_status = HTTPStatus.OK
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        return len(payload)

    def _serve_loop(
        self,
        path: Path,
        *,
        stall_token: str | None = None,
        stall_seconds: float = 0,
        close_token: str | None = None,
    ) -> int:
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        if close_token:
            # A close-delimited HTTP body ends successfully when the socket
            # closes, so it cannot model source loss. Chunked framing makes a
            # close without the terminal zero-length chunk unambiguously
            # incomplete to the media client.
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        transferred = 0
        observed_stall_generation = 0
        if stall_token:
            observed_stall_generation, triggered_at = self.server.stall_state(
                stall_token
            )
            remaining = triggered_at + stall_seconds - time.monotonic()
            if observed_stall_generation > 0 and remaining > 0:
                time.sleep(remaining)
        while True:
            with path.open("rb") as source:
                while chunk := source.read(self.server.chunk_size):
                    if close_token:
                        self.wfile.write(f"{len(chunk):X}\r\n".encode())
                        self.wfile.write(chunk)
                        self.wfile.write(b"\r\n")
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
                    transferred += len(chunk)
                    if stall_token:
                        generation, triggered_at = self.server.stall_state(stall_token)
                        if generation > observed_stall_generation:
                            observed_stall_generation = generation
                            remaining = triggered_at + stall_seconds - time.monotonic()
                            if remaining > 0:
                                time.sleep(remaining)
                    if close_token and self.server.close_generation(close_token) > 0:
                        self.close_connection = True
                        return transferred
                    if self.server.chunk_delay:
                        time.sleep(self.server.chunk_delay)

    def _serve_file(
        self, path: Path, *, stall_seconds: float = 0, close_after: int | None = None
    ) -> int:
        size = path.stat().st_size
        try:
            start, end, partial = self._range(size)
        except RangeNotSatisfiable:
            self.response_status = HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE
            self.response_content_range = f"bytes */{size}"
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header("Content-Range", self.response_content_range)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return 0
        length = end - start + 1
        advertised_length = (
            length if close_after is None else min(length, close_after + 1)
        )
        self.response_status = HTTPStatus.PARTIAL_CONTENT if partial else HTTPStatus.OK
        self.send_response(self.response_status)
        self.send_header(
            "Content-Type",
            mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        )
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.response_content_range = f"bytes {start}-{end}/{size}"
            self.send_header("Content-Range", self.response_content_range)
        self.end_headers()

        transferred = 0
        stalled = False
        with path.open("rb") as source:
            source.seek(start)
            remaining = length
            while remaining:
                limit = min(self.server.chunk_size, remaining)
                if close_after is not None:
                    limit = min(limit, advertised_length - transferred)
                    if limit <= 0:
                        self.close_connection = True
                        return transferred
                chunk = source.read(limit)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                transferred += len(chunk)
                remaining -= len(chunk)
                if stall_seconds and not stalled and transferred >= max(1, length // 4):
                    stalled = True
                    time.sleep(stall_seconds)
        return transferred

    def _serve_progressive_file(
        self, path: Path, *, range_capable: bool, event: dict
    ) -> int:
        """Serve the large seek oracle with deterministic bounded throughput.

        Range mode implements RFC byte ranges. No-Range mode deliberately
        ignores a Range request, returns a complete 200 response, and omits
        Accept-Ranges so VLC's HTTP access reports the source as non-seekable.
        """

        size = path.stat().st_size
        if range_capable:
            try:
                start, end, partial = self._range(size)
            except RangeNotSatisfiable:
                self.response_status = HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE
                self.response_content_range = f"bytes */{size}"
                self.progressive_response_content_length = 0
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Range", self.response_content_range)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return 0
        else:
            start, end, partial = 0, size - 1, False

        length = end - start + 1
        self.response_status = HTTPStatus.PARTIAL_CONTENT if partial else HTTPStatus.OK
        self.progressive_response_content_length = length
        self.send_response(self.response_status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(length))
        if range_capable:
            self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.response_content_range = f"bytes {start}-{end}/{size}"
            self.send_header("Content-Range", self.response_content_range)
        self.end_headers()

        with path.open("rb") as source:
            source.seek(start)
            remaining = length
            while remaining:
                chunk = source.read(min(self.server.chunk_size, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                self.progressive_transferred += len(chunk)
                self.server.update_progressive_request_transfer(
                    event, self.progressive_transferred
                )
                remaining -= len(chunk)
                if self.server.chunk_delay:
                    time.sleep(self.server.chunk_delay)
        return self.progressive_transferred

    def _range(self, size: int) -> tuple[int, int, bool]:
        header = self.headers.get("Range")
        if not header:
            return 0, size - 1, False
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
        if not match or (not match.group(1) and not match.group(2)):
            raise ValueError("unsupported byte range")
        if match.group(1):
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else size - 1
        else:
            suffix = int(match.group(2))
            start = max(0, size - suffix)
            end = size - 1
        if start >= size or end < start:
            raise RangeNotSatisfiable("range outside file")
        return start, min(end, size - 1), True

    def log_message(self, format: str, *args: object) -> None:
        if self.server.verbose:
            super().log_message(format, *args)


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        root: Path,
        request_log: Path | None,
        chunk_size: int,
        chunk_delay: float,
        verbose: bool,
    ) -> None:
        # TCPServer.__init__ invokes the overridden server_close() when bind or
        # activation fails. Establish the close state first so the original
        # socket error survives that cleanup path instead of being masked by a
        # partially initialized FixtureHTTPServer.
        self.request_log = request_log
        self._request_log_lock = threading.Lock()
        self._accepts_request_log_writes = True
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, FixtureHandler)
        self.root = root.resolve()
        self.chunk_size = chunk_size
        self.chunk_delay = chunk_delay
        self.verbose = verbose
        self._stall_lock = threading.Lock()
        self._stall_generations: dict[str, int] = {}
        self._stall_triggered_at: dict[str, float] = {}
        self._close_lock = threading.Lock()
        self._close_generations: dict[str, int] = {}
        self._adaptive_lock = threading.Lock()
        self._adaptive_runs: dict[str, dict] = {}
        self._adaptive_started_at: dict[tuple[str, str, str], float] = {}
        self._adaptive_retry_failures: set[tuple[str, str, str, str]] = set()
        self._progressive_lock = threading.Lock()
        self._progressive_runs: dict[str, dict] = {}

    def _progressive_state(self, token: str) -> dict:
        return self._progressive_runs.setdefault(
            token,
            {
                "nextSequence": 1,
                "commandedModes": set(),
                "events": [],
            },
        )

    def begin_progressive_request(
        self,
        token: str,
        mode: str,
        path: str,
        request_range: str | None,
    ) -> dict:
        with self._progressive_lock:
            state = self._progressive_state(token)
            sequence = state["nextSequence"]
            state["nextSequence"] += 1
            event = {
                "kind": "media-request",
                "sequence": sequence,
                "token": token,
                "mode": mode,
                "phase": (
                    "post-command" if mode in state["commandedModes"] else "pre-command"
                ),
                "method": "GET",
                "path": path,
                "fixtureRelativePath": "oracles/progressive-range.mp4",
                "requestRange": request_range,
                "responseStatus": None,
                "responseContentRange": None,
                "acceptRanges": None,
                "responseContentLength": None,
                "transferredBytes": 0,
                "transferredBytesAtCommand": None,
                "completed": False,
                "startedAtUTC": datetime.now(timezone.utc).isoformat(),
                "completedAtUTC": None,
            }
            state["events"].append(event)
            return event

    def finish_progressive_request(
        self,
        event: dict,
        *,
        response_status: int,
        response_content_range: str | None,
        accept_ranges: str | None,
        response_content_length: int | None,
        transferred_bytes: int,
        completed: bool,
    ) -> None:
        with self._progressive_lock:
            event.update(
                {
                    "responseStatus": response_status,
                    "responseContentRange": response_content_range,
                    "acceptRanges": accept_ranges,
                    "responseContentLength": response_content_length,
                    "transferredBytes": transferred_bytes,
                    "completed": completed,
                    "completedAtUTC": datetime.now(timezone.utc).isoformat(),
                }
            )

    def mark_progressive_command(
        self, token: str, mode: str, *, origin: str | None
    ) -> dict:
        with self._progressive_lock:
            if origin != PROGRESSIVE_COMMAND_ORIGIN:
                raise ValueError("progressive command marker has an invalid origin")
            state = self._progressive_state(token)
            if mode in state["commandedModes"]:
                raise ValueError(
                    f"progressive command marker already exists for {mode}"
                )
            sequence = state["nextSequence"]
            state["nextSequence"] += 1
            state["commandedModes"].add(mode)
            precommand = [
                event
                for event in state["events"]
                if event.get("kind") == "media-request"
                and event.get("mode") == mode
                and event.get("phase") == "pre-command"
            ]
            for event in precommand:
                event["transferredBytesAtCommand"] = event["transferredBytes"]
            event = {
                "kind": "command-marker",
                "sequence": sequence,
                "token": token,
                "mode": mode,
                "phase": "post-command",
                "origin": origin,
                "precommandRequestCount": len(precommand),
                "precommandTransferredBytes": sum(
                    item["transferredBytesAtCommand"] for item in precommand
                ),
                "markedAtUTC": datetime.now(timezone.utc).isoformat(),
            }
            state["events"].append(event)
            return event

    def update_progressive_request_transfer(
        self, event: dict, transferred_bytes: int
    ) -> None:
        with self._progressive_lock:
            event["transferredBytes"] = transferred_bytes

    def progressive_transcript(self, token: str) -> dict:
        path = self.root / "oracles" / "progressive-range.mp4"
        if not path.is_file():
            raise FileNotFoundError(path)
        with self._progressive_lock:
            state = self._progressive_state(token)
            return {
                "formatVersion": 1,
                "token": token,
                "fixtureRelativePath": "oracles/progressive-range.mp4",
                "fixtureBytes": path.stat().st_size,
                "events": json.loads(json.dumps(state["events"])),
            }

    @staticmethod
    def adaptive_container(mode: str) -> str:
        if mode in {"event-fmp4", "live-fmp4", "abr-high-fmp4"}:
            return "fmp4"
        if mode in {
            "vod-ts",
            "live-ts",
            "retry-ts",
            "abr-ts",
            "abr-low-ts",
            "timebase-vod-ts",
        }:
            return "ts"
        raise ValueError(f"unsupported adaptive mode: {mode}")

    @staticmethod
    def adaptive_playlist_type(mode: str) -> str:
        if mode == "event-fmp4":
            return "event"
        if mode in {"live-ts", "live-fmp4", "retry-ts", "abr-ts"}:
            return "live"
        return "vod"

    def _adaptive_state(self, token: str) -> dict:
        return self._adaptive_runs.setdefault(
            token,
            {
                "masterRequests": 0,
                "mediaPlaylistRequests": 0,
                "segmentRequests": 0,
                "successfulSegments": 0,
                "successfulSegmentsByVariant": {"low": 0, "high": 0},
                "retryFailures": 0,
                "retryRecoveries": 0,
                "expiredWindows": 0,
                "discontinuityManifests": 0,
                "variantTransitions": 0,
                "lastVariantByMode": {},
                "clientCompleted": False,
                "playlistTypes": set(),
                "containers": set(),
                "variants": set(),
                "modes": set(),
                "maxMediaSequenceByMode": {},
            },
        )

    def adaptive_master(self, token: str, mode: str) -> str:
        container = self.adaptive_container(mode)
        playlist_type = self.adaptive_playlist_type(mode)
        variants = ["low", "high"]
        if mode == "abr-low-ts":
            variants = ["low"]
        elif mode in {"abr-high-fmp4", "timebase-vod-ts"}:
            variants = ["high"]
        with self._adaptive_lock:
            state = self._adaptive_state(token)
            state["masterRequests"] += 1
            state["playlistTypes"].add(playlist_type)
            state["containers"].add(container)
            state["modes"].add(mode)
        lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        records = {
            "low": (300_000, "320x180"),
            "high": (1_200_000, "640x360"),
        }
        for variant in variants:
            bandwidth, resolution = records[variant]
            lines.extend(
                [
                    f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},AVERAGE-BANDWIDTH={bandwidth},RESOLUTION={resolution},CODECS="avc1.42c01e,mp4a.40.2"',
                    f"{variant}.m3u8",
                ]
            )
        return "\n".join(lines) + "\n"

    def adaptive_media_playlist(self, token: str, mode: str, variant: str) -> str:
        container = self.adaptive_container(mode)
        playlist_type = self.adaptive_playlist_type(mode)
        directory = self.root / "hls" / "soak" / container / variant
        suffix = ".ts" if container == "ts" else ".m4s"
        segments = sorted(directory.glob(f"segment-*{suffix}"))
        if len(segments) < 4:
            raise FileNotFoundError(f"insufficient adaptive segments in {directory}")

        key = (token, mode, variant)
        now = time.monotonic()
        with self._adaptive_lock:
            started = self._adaptive_started_at.setdefault(key, now)
            state = self._adaptive_state(token)
            state["mediaPlaylistRequests"] += 1
            state["playlistTypes"].add(playlist_type)
            state["containers"].add(container)
            state["variants"].add(variant)
            state["modes"].add(mode)

        is_live = playlist_type == "live"
        is_subtitle_vod = mode in {"abr-low-ts", "abr-high-fmp4"}
        is_timebase_vod = mode == "timebase-vod-ts"
        media_sequence = int((now - started) / 2) if is_live else 0
        if is_live:
            window_count = min(6, len(segments))
            indices = range(media_sequence, media_sequence + window_count)
        elif is_subtitle_vod:
            # The subtitle matrix owns each ABR profile for about 84 seconds.
            # Reuse the deterministic two-second media segments to publish a
            # real 120-second seekable timeline without duplicating fixture
            # bytes. A discontinuity at every wrap resets segment timestamps
            # while the playlist timeline remains monotonic.
            indices = range(max(len(segments), 60))
        elif is_timebase_vod:
            # The rate schedule can consume more than 8,000 media seconds
            # during a 7,200-second wall-clock qualification run. Publish a
            # four-hour seekable timeline so the 0.5x, 1x, and 2x phases,
            # replacement, and AVPlayer baseline can never reach EOF.
            indices = range(TIMEBASE_VOD_SECONDS // ADAPTIVE_SEGMENT_SECONDS)
        else:
            indices = range(len(segments))

        discontinuity = (
            playlist_type == "event" or is_live or is_subtitle_vod or is_timebase_vod
        )
        lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7" if container == "fmp4" else "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:2",
            f"#EXT-X-MEDIA-SEQUENCE:{media_sequence}",
        ]
        if playlist_type == "vod":
            lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        elif playlist_type == "event":
            lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
        if container == "fmp4":
            lines.append(f'#EXT-X-MAP:URI="{variant}/init.mp4"')

        midpoint = max(1, len(segments) // 2)
        if is_live:
            discontinuities_before_window = 0
            if media_sequence > midpoint:
                discontinuities_before_window = 1 + (
                    media_sequence - 1 - midpoint
                ) // len(segments)
            lines.append(
                f"#EXT-X-DISCONTINUITY-SEQUENCE:{discontinuities_before_window}"
            )
        for offset, sequence in enumerate(indices):
            should_discontinue = (
                (playlist_type == "event" and offset == midpoint)
                or (is_live and sequence % len(segments) == midpoint)
                or (
                    (is_subtitle_vod or is_timebase_vod)
                    and offset > 0
                    and sequence % len(segments) == 0
                )
            )
            if should_discontinue:
                lines.append("#EXT-X-DISCONTINUITY")
            segment = segments[sequence % len(segments)]
            uri = f"{variant}/{segment.name}"
            if is_live or is_timebase_vod:
                uri += f"?sequence={sequence}"
            lines.extend(["#EXTINF:2.000,", uri])
        if not is_live:
            lines.append("#EXT-X-ENDLIST")

        with self._adaptive_lock:
            state = self._adaptive_state(token)
            previous = state["maxMediaSequenceByMode"].get(mode, -1)
            if media_sequence > previous:
                if previous >= 0:
                    state["expiredWindows"] += media_sequence - previous
                state["maxMediaSequenceByMode"][mode] = media_sequence
            if discontinuity:
                state["discontinuityManifests"] += 1
        return "\n".join(lines) + "\n"

    def should_fail_adaptive_asset(
        self, token: str, mode: str, variant: str, filename: str
    ) -> bool:
        if mode != "retry-ts" or filename == "init.mp4":
            return False
        key = (token, mode, variant, filename)
        with self._adaptive_lock:
            state = self._adaptive_state(token)
            state["segmentRequests"] += 1
            state["variants"].add(variant)
            self._record_adaptive_variant(state, mode, variant)
            if key not in self._adaptive_retry_failures:
                self._adaptive_retry_failures.add(key)
                state["retryFailures"] += 1
                return True
        return False

    def record_adaptive_asset(
        self, token: str, mode: str, variant: str, filename: str, recovered: bool
    ) -> None:
        with self._adaptive_lock:
            state = self._adaptive_state(token)
            if (
                mode != "retry-ts"
                or (token, mode, variant, filename) not in self._adaptive_retry_failures
            ):
                state["segmentRequests"] += 1
            state["successfulSegments"] += 1
            state["successfulSegmentsByVariant"][variant] += 1
            state["variants"].add(variant)
            self._record_adaptive_variant(state, mode, variant)
            if (
                recovered
                and (token, mode, variant, filename) in self._adaptive_retry_failures
            ):
                state["retryRecoveries"] += 1

    def adaptive_metrics(self, token: str) -> dict:
        with self._adaptive_lock:
            state = self._adaptive_state(token)
            return {
                "formatVersion": 1,
                "token": token,
                **{
                    key: sorted(value) if isinstance(value, set) else value
                    for key, value in state.items()
                    if key != "lastVariantByMode"
                },
            }

    @staticmethod
    def _record_adaptive_variant(state: dict, mode: str, variant: str) -> None:
        # Only abr-ts advertises both representations in one master. Moving
        # between separate one-variant URLs is a test phase change, not an ABR
        # switch performed by the player.
        if mode != "abr-ts":
            return
        previous = state["lastVariantByMode"].get(mode)
        if previous not in {None, variant}:
            state["variantTransitions"] += 1
        state["lastVariantByMode"][mode] = variant

    def complete_adaptive_run(self, token: str) -> dict:
        with self._adaptive_lock:
            state = self._adaptive_state(token)
            state["clientCompleted"] = True
            return {"clientCompleted": True}

    def trigger_stall(self, token: str) -> int:
        with self._stall_lock:
            generation = self._stall_generations.get(token, 0) + 1
            self._stall_generations[token] = generation
            self._stall_triggered_at[token] = time.monotonic()
            return generation

    def stall_state(self, token: str) -> tuple[int, float]:
        with self._stall_lock:
            return (
                self._stall_generations.get(token, 0),
                self._stall_triggered_at.get(token, 0),
            )

    def trigger_close(self, token: str) -> int:
        with self._close_lock:
            generation = self._close_generations.get(token, 0) + 1
            self._close_generations[token] = generation
            return generation

    def close_generation(self, token: str) -> int:
        with self._close_lock:
            return self._close_generations.get(token, 0)

    def handle_error(self, request: object, client_address: tuple[str, int]) -> None:
        # Media clients commonly abandon a keep-alive connection after a seek
        # or EOF probe. BaseServer otherwise prints a full traceback even
        # though the request itself completed and was recorded successfully.
        # Preserve tracebacks for every unexpected server failure.
        error = sys.exc_info()[1]
        if isinstance(error, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)

    def server_close(self) -> None:
        super().server_close()
        # Request handlers are intentionally daemon threads, so the standard
        # ThreadingHTTPServer close does not join them. Serialize this boundary
        # with record(): any write already in progress finishes before close
        # returns, while a handler that finishes later observes the closed log
        # and cannot recreate it after its owner removes the fixture directory.
        with self._request_log_lock:
            self._accepts_request_log_writes = False

    def record(self, value: dict) -> None:
        with self._request_log_lock:
            if self.request_log is None or not self._accepts_request_log_writes:
                return
            with self.request_log.open("a") as output:
                output.write(json.dumps(value, sort_keys=True) + "\n")


def lan_address() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(("192.0.2.1", 80))
        return connection.getsockname()[0]


def advertised_url(host: str, port: int) -> str:
    url_host = f"[{host}]" if ":" in host else host
    return f"http://{url_host}:{port}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--advertise-host")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--request-log", type=Path)
    parser.add_argument("--chunk-size", type=int, default=7520)
    parser.add_argument("--chunk-delay", type=float, default=0.02)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not args.root.is_dir():
        parser.error(f"fixture root does not exist: {args.root}")
    server = FixtureHTTPServer(
        (args.host, args.port),
        args.root,
        args.request_log,
        args.chunk_size,
        args.chunk_delay,
        args.verbose,
    )
    advertised = args.advertise_host or lan_address()
    ready = {
        "host": advertised,
        "port": server.server_port,
        "baseURL": advertised_url(advertised, server.server_port),
        "controlURL": advertised_url(
            "::1" if server.address_family == socket.AF_INET6 else "127.0.0.1",
            server.server_port,
        ),
    }
    if args.ready_file:
        atomic_write_json(args.ready_file, ready)
    print(json.dumps(ready, sort_keys=True), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
