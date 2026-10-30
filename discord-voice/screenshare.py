#!/usr/bin/env python3
"""Local addition: toggle Discord screen share from a keybind.

service.luau runs this for the ``toggle-screenshare`` IPC event:

    python3 screenshare.py toggle

Discord only allows its TOGGLE_SCREENSHARE command with the
``rpc.screenshare.write`` scope, which the bridge's token doesn't have.
Instead of changing the bridge, this script keeps its own token and opens its
own short-lived connection, so mute/deafen are never affected. The first press
shows Discord's Authorize prompt once; later tokens are renewed silently.

Starting a share opens Discord's picker (you must be in a call); pressing again
while sharing stops it. Prints one JSON line: {"ok": true} or
{"ok": false, "error": "..."}.

Python 3.10+ standard library only.
"""

from __future__ import annotations

import fcntl
import json
import os
import socket
import struct
import sys
import tempfile
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Any

CLIENT_ID = "207646673902501888"  # Discord StreamKit, same as the bridge
# The voice scopes are included so a grant made here also covers the bridge.
SCOPES = ["rpc", "rpc.voice.read", "rpc.voice.write", "rpc.screenshare.write"]
SHARE_SCOPE = "rpc.screenshare.write"
TOKEN_URL = "https://streamkit.discord.com/overlay/token"
USER_AGENT = "Noctalia-Discord-Voice"

# Noctalia stops a runAsync command after 60 s; finish (or fail) before that.
DEADLINE = time.monotonic() + 55
STEP_SECONDS = 5

OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = range(5)


class DiscordError(Exception):
    def __init__(self, message: str, code: int | None = None) -> None:
        super().__init__(message)
        self.code = code


def remaining(until: float | None = None) -> float:
    """Seconds left before ``until`` (default: one step) or the overall deadline."""
    now = time.monotonic()
    end = min(DEADLINE, until if until is not None else now + STEP_SECONDS)
    if end <= now:
        raise DiscordError("Timed out waiting for Discord")
    return end - now


def runtime_dir() -> Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    return Path(runtime) if runtime else Path(tempfile.gettempdir())


def state_dir() -> Path:
    # Same directory as the bridge's token.json.
    root = os.environ.get("NOCTALIA_STATE_HOME") or os.environ.get("XDG_STATE_HOME")
    base = Path(root).expanduser() if root else Path("~/.local/state").expanduser()
    return base / "noctalia" / "discord-voice"


TOKEN_FILE = state_dir() / "screenshare-token.json"


def load_token() -> str | None:
    try:
        token = json.loads(TOKEN_FILE.read_text(encoding="utf-8")).get("access_token")
    except (OSError, ValueError, AttributeError):
        return None
    return token if isinstance(token, str) and token else None


def save_token(token: str) -> None:
    TOKEN_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(TOKEN_FILE.parent, 0o700)
    fd, temporary = tempfile.mkstemp(dir=TOKEN_FILE.parent, prefix=".screenshare-token.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"access_token": token}, handle)
        os.chmod(temporary, 0o600)
        os.replace(temporary, TOKEN_FILE)
    finally:
        Path(temporary).unlink(missing_ok=True)


def clear_token() -> None:
    TOKEN_FILE.unlink(missing_ok=True)


def socket_candidates() -> list[Path]:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    directories: list[Path] = []
    if runtime:
        directories += [
            Path(runtime),
            Path(runtime) / "app" / "com.discordapp.Discord",
            Path(runtime) / "snap.discord",
        ]
    for variable in ("TMPDIR", "TMP", "TEMP"):
        if os.environ.get(variable):
            directories.append(Path(os.environ[variable]))
    directories.append(Path("/tmp"))
    return [directory / f"discord-ipc-{n}" for directory in directories for n in range(10)]


class Discord:
    """One connection to the Discord desktop client's local RPC socket."""

    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        for path in socket_candidates():
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(remaining())
            try:
                sock.connect(str(path))
                credentials = sock.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
                )
            except OSError:
                sock.close()
                continue
            if struct.unpack("3i", credentials)[1] != os.geteuid():
                sock.close()  # someone else's socket, e.g. in a shared /tmp
                continue
            self.sock = sock
            break
        if self.sock is None:
            raise DiscordError("Discord isn't running")
        self.send(OP_HANDSHAKE, {"v": 1, "client_id": CLIENT_ID})
        op, message = self.receive(remaining())
        if op == OP_CLOSE or message.get("evt") != "READY":
            raise DiscordError(f"Discord refused the connection: {message.get('message', message)}")

    def close(self) -> None:
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def send(self, op: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode()
        try:
            self.sock.sendall(struct.pack("<II", op, len(data)) + data)
        except OSError as error:
            raise DiscordError(f"Lost the connection to Discord: {error}") from None

    def read_exactly(self, size: int) -> bytes:
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise DiscordError("Discord closed the connection")
            data += chunk
        return data

    def receive(self, timeout: float) -> tuple[int, dict[str, Any]]:
        self.sock.settimeout(timeout)
        try:
            op, size = struct.unpack("<II", self.read_exactly(8))
            message = json.loads(self.read_exactly(size))
        except socket.timeout:
            raise DiscordError("Timed out waiting for Discord") from None
        except OSError as error:
            raise DiscordError(f"Lost the connection to Discord: {error}") from None
        return op, message if isinstance(message, dict) else {}

    def call(self, cmd: str, args: dict[str, Any], until: float | None = None) -> dict[str, Any]:
        """Send a command and return its reply's data; ``until`` caps the wait."""
        if until is None:
            until = time.monotonic() + STEP_SECONDS
        nonce = str(uuid.uuid4())
        self.send(OP_FRAME, {"cmd": cmd, "args": args, "nonce": nonce})
        while True:
            op, message = self.receive(remaining(until))
            if op == OP_CLOSE:
                raise DiscordError(message.get("message", "Discord closed the connection"))
            if op == OP_PING:
                self.send(OP_PONG, message)
                continue
            if message.get("nonce") != nonce:
                continue  # an event, or a reply to something else
            data = message.get("data")
            if message.get("evt") == "ERROR":
                error = data if isinstance(data, dict) else {}
                raise DiscordError(error.get("message", f"{cmd} failed"), error.get("code"))
            return data if isinstance(data, dict) else {}


def authorize(discord: Discord) -> str:
    """Get a new token. Shows Discord's prompt unless already approved."""
    reply = discord.call(
        "AUTHORIZE",
        {"client_id": CLIENT_ID, "scopes": SCOPES, "prompt": "none"},
        until=DEADLINE,  # time to click Authorize in Discord
    )
    code = reply.get("code")
    if not isinstance(code, str) or not code:
        raise DiscordError("Discord authorization was not completed")
    request = urllib.request.Request(
        TOKEN_URL,
        data=json.dumps({"code": code}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=remaining(time.monotonic() + 10)) as response:
            token = json.loads(response.read().decode()).get("access_token")
    except (OSError, ValueError) as error:
        raise DiscordError(f"StreamKit token exchange failed: {error}") from None
    if not isinstance(token, str) or not token:
        raise DiscordError("StreamKit returned no access token")
    save_token(token)
    return token


def authenticated_connection() -> Discord:
    """Connect and authenticate with a token that has the screen-share scope."""
    discord = Discord()
    token = load_token()
    if token:
        try:
            auth = discord.call("AUTHENTICATE", {"access_token": token})
        except DiscordError as error:
            if error.code is None:
                raise  # connection trouble, not a bad token
            clear_token()  # expired or revoked; authorize on this connection
        else:
            if SHARE_SCOPE in auth.get("scopes", []):
                return discord
            # Discord refuses AUTHORIZE once a connection has authenticated,
            # so authorize on a fresh one.
            clear_token()
            discord.close()
            discord = Discord()

    auth = discord.call("AUTHENTICATE", {"access_token": authorize(discord)})
    if SHARE_SCOPE not in auth.get("scopes", []):
        clear_token()
        raise DiscordError("Discord didn't give StreamKit the screen-share permission")
    return discord


def toggle() -> dict[str, Any]:
    lock_path = runtime_dir() / "noctalia-discord-screenshare.lock"
    with open(lock_path, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"ok": True, "skipped": "already running"}  # double press
        discord = authenticated_connection()
        try:
            discord.call("TOGGLE_SCREENSHARE", {})
        finally:
            discord.close()
    return {"ok": True}


def main() -> int:
    if sys.argv[1:] != ["toggle"]:
        print(json.dumps({"ok": False, "error": "usage: screenshare.py toggle"}))
        return 2
    try:
        result = toggle()
    except DiscordError as error:
        result = {"ok": False, "error": str(error)}
    except Exception as error:  # never leave Noctalia with no output
        result = {"ok": False, "error": f"{type(error).__name__}: {error}"}
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
