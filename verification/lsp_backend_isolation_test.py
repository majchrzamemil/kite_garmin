#!/usr/bin/env python3
"""
[Isolation test, not editor integration]

Proof that the Connect IQ LanguageServer.jar accepts a JSON-RPC
textDocument/didOpen for source/App.mc.

This test boots the SDK's LanguageServer.jar in isolation (no editor
involved). It sends a real JSON-RPC exchange (initialize → initialized →
textDocument/didOpen for source/App.mc) and asserts that the LSP responds
with a window/logMessage acknowledging the didOpen for that URI.

This proves the LSP backend works. It does NOT prove that any particular
editor (VS Code, Neovim, etc.) successfully attaches it. For editor
integration, see verification/editor_integration_test.sh which boots VS
Code with the project and inspects VS Code's own extension-host log for
"extension activated" events.

Usage: ./verification/lsp_backend_isolation_test.py
Expected exit: 0 on success, 1 on failure
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
JAR = (
    Path.home()
    / "Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2"
    / "bin/LanguageServer.jar"
)

if not JAR.is_file():
    print(f"FAIL: LanguageServer.jar not found at {JAR}", file=sys.stderr)
    sys.exit(1)

app_mc = (PROJECT_ROOT / "source" / "App.mc").read_text()
expected_uri = f"file://{PROJECT_ROOT}/source/App.mc"


def frame(msg: dict) -> bytes:
    body = json.dumps(msg)
    return f"Content-Length: {len(body)}\r\n\r\n{body}".encode("utf-8")


init = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "processId": os.getpid(),
        "rootUri": f"file://{PROJECT_ROOT}",
        "capabilities": {
            "textDocument": {
                "synchronization": {"dynamicRegistration": True},
                "hover": {"contentFormat": ["plaintext"]},
            },
            "workspace": {"workspaceFolders": True},
        },
    },
}
initialized = {"jsonrpc": "2.0", "method": "initialized", "params": {}}
didopen = {
    "jsonrpc": "2.0",
    "method": "textDocument/didOpen",
    "params": {
        "textDocument": {
            "uri": expected_uri,
            "languageId": "monkeyc",
            "version": 1,
            "text": app_mc,
        }
    },
}

# Spawn the LSP with our stdin pipe so we can drive the JSON-RPC exchange.
proc = subprocess.Popen(
    ["java", "-classpath", str(JAR), "com.garmin.monkeybrains.languageserver.LSLauncher"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

# Send initialize, initialized, didOpen with a short pause between each so the
# LSP has time to process. Then close stdin so the LSP exits cleanly.
proc.stdin.write(frame(init))
proc.stdin.flush()
time.sleep(0.5)
proc.stdin.write(frame(initialized))
proc.stdin.flush()
time.sleep(0.5)
proc.stdin.write(frame(didopen))
proc.stdin.flush()
time.sleep(5)
proc.stdin.close()

# Wait for LSP to finish (it may have already).
try:
    stdout, stderr = proc.communicate(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    stdout, stderr = proc.communicate()

stdout_str = stdout.decode("utf-8", errors="replace")
# LSP escapes apostrophes inside JSON string values as \u0027. Match against
# both the literal form (what VS Code would receive) and the escaped form
# (what shows up on the wire).
expected_literal = f"Recieved textDocument/didOpen notification for URI '{expected_uri}'"
expected_escaped = expected_literal.replace("'", "\\u0027")
# A simpler signature that doesn't depend on quoting: the LSP logs the exact
# file path it received. Match on that substring plus the message prefix.
expected_signature = f"Recieved textDocument/didOpen notification for URI"
expected_uri_signature = expected_uri
if (expected_literal in stdout_str
        or expected_escaped in stdout_str
        or (expected_signature in stdout_str and expected_uri_signature in stdout_str)):
    print("PASS: LSP attached — source/App.mc processed by com.garmin.monkeybrains.languageserver.LSLauncher")
    print(f"  jar:    {JAR}")
    print(f"  proof:  window/logMessage acknowledged didOpen for {expected_uri}")
    sys.exit(0)
else:
    print(f"FAIL: LSP did not acknowledge didOpen for source/App.mc", file=sys.stderr)
    print(f"--- stderr (last 20 lines) ---", file=sys.stderr)
    print("\n".join(stderr.decode("utf-8", errors="replace").splitlines()[-20:]), file=sys.stderr)
    print(f"--- stdout (last 30 lines) ---", file=sys.stderr)
    print("\n".join(stdout_str.splitlines()[-30:]), file=sys.stderr)
    sys.exit(1)
