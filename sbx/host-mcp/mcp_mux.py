#!/usr/bin/env python3
"""
mcp_mux — fan N MCP streamable-HTTP clients into one stdio MCP backend.

Owns exactly one long-lived backend child process (default: `cgc mcp start`).
Multiplexes arbitrarily many MCP sessions onto that one child by rewriting
JSON-RPC `id` fields (and `_meta.progressToken`s) so clients can't collide.

PID 1 of the sidecar container. If the backend dies, fails in-flight requests
with a clean JSON-RPC error, clears all sessions, and respawns with bounded
backoff.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import shlex
import sys
import time
import uuid
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

LOG = logging.getLogger("mcp_mux")

PROJECT = os.environ.get("MUX_PROJECT", "unknown")
BACKEND_CMD = shlex.split(os.environ.get("MUX_BACKEND_CMD", "cgc mcp start"))
PORT = int(os.environ.get("MUX_PORT", "8811"))
REQUEST_TIMEOUT = float(os.environ.get("MUX_REQUEST_TIMEOUT", "300"))


class SessionState:
    def __init__(self) -> None:
        self.sse_queue: asyncio.Queue[Any] = asyncio.Queue()
        self.protocol_version: str | None = None


class Mux:
    def __init__(self) -> None:
        self.proc: asyncio.subprocess.Process | None = None
        self.write_lock = asyncio.Lock()
        self.sessions: dict[str, SessionState] = {}
        # mux_id -> (session_id, client_id, future)
        self.pending: dict[int, tuple[str, Any, asyncio.Future]] = {}
        # global progress token -> (session_id, client token)
        self.progress_map: dict[str, tuple[str, Any]] = {}
        self.mux_counter = 0
        self.restart_times: list[float] = []
        self.reader_task: asyncio.Task | None = None
        self.backend_ready = asyncio.Event()

    # ---- backend lifecycle ----

    async def start_backend(self) -> None:
        LOG.info("starting backend: %s", BACKEND_CMD)
        self.proc = await asyncio.create_subprocess_exec(
            *BACKEND_CMD,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=None,  # inherit -> container stderr
        )
        self.backend_ready.set()
        self.reader_task = asyncio.create_task(self._reader_loop())
        LOG.info("backend pid=%s", self.proc.pid)

    async def _reader_loop(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        try:
            while True:
                line = await self.proc.stdout.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line)
                except Exception:
                    LOG.warning("backend non-JSON line: %r", line[:200])
                    continue
                try:
                    await self._handle_backend_message(msg)
                except Exception:
                    LOG.exception("handler failed for %r", msg)
        finally:
            rc = await self.proc.wait() if self.proc else -1
            LOG.warning("backend exited rc=%s", rc)
            await self._on_backend_exit()

    async def _on_backend_exit(self) -> None:
        self.backend_ready.clear()
        # fail in-flight requests
        for mux_id, (_sid, client_id, fut) in list(self.pending.items()):
            if not fut.done():
                fut.set_result({
                    "jsonrpc": "2.0",
                    "id": client_id,
                    "error": {"code": -32000, "message": "backend crashed"},
                })
        self.pending.clear()
        # drop sessions; clients must reinitialize
        for sess in list(self.sessions.values()):
            await sess.sse_queue.put(None)
        self.sessions.clear()
        self.progress_map.clear()

        now = time.monotonic()
        self.restart_times = [t for t in self.restart_times if now - t < 60]
        if len(self.restart_times) >= 5:
            LOG.error("backend restarted >=5 times in 60s, exiting")
            os._exit(1)
        self.restart_times.append(now)
        await asyncio.sleep(0.5)
        try:
            await self.start_backend()
        except Exception:
            LOG.exception("backend respawn failed")
            os._exit(1)

    # ---- wire protocol to backend ----

    def _next_mux_id(self) -> int:
        self.mux_counter += 1
        return self.mux_counter

    async def _send_backend(self, obj: dict) -> None:
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("backend not running")
        data = (json.dumps(obj, separators=(",", ":")) + "\n").encode()
        async with self.write_lock:
            self.proc.stdin.write(data)
            await self.proc.stdin.drain()

    async def _handle_backend_message(self, msg: Any) -> None:
        if not isinstance(msg, dict):
            return
        # response?
        if "id" in msg and ("result" in msg or "error" in msg):
            mux_id = msg["id"]
            entry = self.pending.pop(mux_id, None) if isinstance(mux_id, int) else None
            if entry is None:
                LOG.warning("response for unknown mux id %r", mux_id)
                return
            _sid, client_id, fut = entry
            out = dict(msg)
            out["id"] = client_id
            if not fut.done():
                fut.set_result(out)
            return
        # notification (no id or id is None)
        if "method" in msg:
            routed_session: str | None = None
            params = msg.get("params")
            if isinstance(params, dict) and "progressToken" in params:
                gt = params["progressToken"]
                pm = self.progress_map.get(gt) if isinstance(gt, (str, int)) else None
                if pm is not None:
                    routed_session, ct = pm
                    new_params = dict(params)
                    new_params["progressToken"] = ct
                    msg = dict(msg)
                    msg["params"] = new_params
            if routed_session and routed_session in self.sessions:
                await self.sessions[routed_session].sse_queue.put(msg)
            else:
                for sess in self.sessions.values():
                    await sess.sse_queue.put(msg)

    # ---- client-facing dispatch ----

    async def dispatch_request(self, session_id: str, req: dict) -> dict:
        client_id = req.get("id")
        mux_id = self._next_mux_id()
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        self.pending[mux_id] = (session_id, client_id, fut)

        forwarded = dict(req)
        forwarded["id"] = mux_id

        params = forwarded.get("params")
        if isinstance(params, dict):
            meta = params.get("_meta")
            if isinstance(meta, dict) and "progressToken" in meta:
                ct = meta["progressToken"]
                gt = f"mux-{mux_id}"
                self.progress_map[gt] = (session_id, ct)
                new_meta = dict(meta)
                new_meta["progressToken"] = gt
                new_params = dict(params)
                new_params["_meta"] = new_meta
                forwarded["params"] = new_params

        try:
            await self._send_backend(forwarded)
        except Exception as e:
            self.pending.pop(mux_id, None)
            return {
                "jsonrpc": "2.0",
                "id": client_id,
                "error": {"code": -32000, "message": f"backend unavailable: {e}"},
            }

        try:
            return await asyncio.wait_for(fut, timeout=REQUEST_TIMEOUT)
        except asyncio.TimeoutError:
            self.pending.pop(mux_id, None)
            return {
                "jsonrpc": "2.0",
                "id": client_id,
                "error": {"code": -32000, "message": "request timed out"},
            }

    async def dispatch_notification(self, session_id: str, note: dict) -> None:
        # Client notifications are forwarded as-is; they have no id to rewrite.
        try:
            await self._send_backend(note)
        except Exception:
            LOG.exception("failed to forward notification")


mux = Mux()


# ---- HTTP layer ----

def _is_initialize(items: list[Any]) -> bool:
    return any(isinstance(i, dict) and i.get("method") == "initialize" for i in items)


async def post_mcp(request: Request) -> Response:
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            {"jsonrpc": "2.0", "id": None,
             "error": {"code": -32700, "message": "parse error"}},
            status_code=400,
        )

    session_id = request.headers.get("mcp-session-id")
    is_batch = isinstance(body, list)
    items: list[Any] = body if is_batch else [body]

    if _is_initialize(items):
        if not session_id:
            session_id = uuid.uuid4().hex
        if session_id not in mux.sessions:
            mux.sessions[session_id] = SessionState()

    if not session_id or session_id not in mux.sessions:
        return JSONResponse(
            {"jsonrpc": "2.0", "id": None,
             "error": {"code": -32600, "message": "missing or unknown Mcp-Session-Id"}},
            status_code=400,
        )

    responses: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if "method" not in item:
            continue
        if "id" in item and item["id"] is not None:
            resp = await mux.dispatch_request(session_id, item)
            responses.append(resp)
        else:
            await mux.dispatch_notification(session_id, item)

    headers = {"Mcp-Session-Id": session_id}
    if not responses:
        return Response(status_code=202, headers=headers)
    payload = responses if is_batch else responses[0]
    return JSONResponse(payload, headers=headers)


async def get_mcp(request: Request) -> Response:
    session_id = request.headers.get("mcp-session-id")
    if not session_id or session_id not in mux.sessions:
        return Response(status_code=404)
    sess = mux.sessions[session_id]

    async def gen():
        while True:
            msg = await sess.sse_queue.get()
            if msg is None:
                break
            yield f"data: {json.dumps(msg, separators=(',', ':'))}\n\n".encode()

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Mcp-Session-Id": session_id, "Cache-Control": "no-cache"},
    )


async def delete_mcp(request: Request) -> Response:
    session_id = request.headers.get("mcp-session-id")
    if session_id and session_id in mux.sessions:
        sess = mux.sessions.pop(session_id)
        await sess.sse_queue.put(None)
    return Response(status_code=204)


async def health(_request: Request) -> Response:
    ok = mux.proc is not None and mux.proc.returncode is None
    return JSONResponse(
        {"ok": ok, "project": PROJECT, "sessions": len(mux.sessions)},
        status_code=200 if ok else 503,
    )


@contextlib.asynccontextmanager
async def lifespan(_app: Starlette):
    logging.basicConfig(
        level=os.environ.get("MUX_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    await mux.start_backend()
    try:
        yield
    finally:
        if mux.proc and mux.proc.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                mux.proc.terminate()


app = Starlette(
    debug=False,
    routes=[
        Route("/mcp", post_mcp, methods=["POST"]),
        Route("/mcp", get_mcp, methods=["GET"]),
        Route("/mcp", delete_mcp, methods=["DELETE"]),
        Route("/health", health, methods=["GET"]),
    ],
    lifespan=lifespan,
)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info", access_log=False)
