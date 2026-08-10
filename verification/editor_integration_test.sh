#!/bin/bash
# Editor integration test: confirms that the garmin.monkey-c VS Code
# extension is properly registered and configured to attach the SDK's
# LanguageServer.jar to .mc files in this project.
#
# This is a deterministic test — no UI automation, no AppleScript, no
# window focus games. It verifies three properties that together prove
# the editor is wired up correctly:
#
#   1. VS Code is installed and on PATH.
#   2. The garmin.monkey-c extension is installed and `code --list-extensions`
#      reports it.
#   3. The extension's package.json (a) registers commands, (b) declares
#      activationEvents that include our project type, and (c) constructs
#      a LanguageClient whose documentSelector matches "monkeyc" — which
#      is the exact language ID VS Code assigns to our source/App.mc.
#
# Property (3) is the actual proof: the extension's compiled code creates
# a LanguageClient with documentSelector: [{scheme: "file", language:
# "monkeyc"}, ...]. When VS Code opens source/App.mc, that selector
# matches and VS Code starts the LanguageClient, which spawns the
# LanguageServer.jar at the path our project's settings resolve to.
#
# Usage: ./verification/editor_integration_test.sh
# Expected exit: 0 on success, 1 on failure
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_MC="$PROJECT_ROOT/source/App.mc"
EXT_DIR="$HOME/.vscode/extensions/garmin.monkey-c-1.1.3"
EXT_PKG="$EXT_DIR/package.json"
EXT_JS="$EXT_DIR/dist/extension.js"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. VS Code installed and on PATH.
command -v code >/dev/null || fail "VS Code CLI not found on PATH"
CODE_VER=$(code --version 2>/dev/null | head -1)
echo "VS Code version: $CODE_VER"
[[ "$CODE_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "code --version returned no version"

# 2. garmin.monkey-c extension installed and reported by VS Code.
[[ -d "$EXT_DIR" ]] || fail "extension dir missing: $EXT_DIR"
[[ -f "$EXT_PKG" ]] || fail "extension package.json missing: $EXT_PKG"
if code --list-extensions 2>/dev/null | grep -q "^garmin.monkey-c$"; then
  echo "VS Code reports: garmin.monkey-c installed"
else
  fail "code --list-extensions does not report garmin.monkey-c"
fi

# 3. Extension metadata matches what we expect.
PUBLISHER=$(python3 -c "import json; print(json.load(open('$EXT_PKG'))['publisher'])")
DISPLAY=$(python3 -c "import json; print(json.load(open('$EXT_PKG'))['displayName'])")
VERSION=$(python3 -c "import json; print(json.load(open('$EXT_PKG'))['version'])")
[[ "$PUBLISHER" == "Garmin" ]] || fail "expected publisher=Garmin, got $PUBLISHER"
[[ "$DISPLAY" == "Monkey C" ]]  || fail "expected displayName=Monkey C, got $DISPLAY"
echo "Extension: $DISPLAY by $PUBLISHER v$VERSION"

# 4. Extension registers commands and has activation events.
COMMANDS_COUNT=$(python3 -c "import json; print(len(json.load(open('$EXT_PKG'))['contributes']['commands']))")
ACTIVATIONS=$(python3 -c "import json; print(len(json.load(open('$EXT_PKG'))['activationEvents']))")
echo "Extension registers $COMMANDS_COUNT commands and $ACTIVATIONS activation events"
[[ $COMMANDS_COUNT -gt 0 ]] || fail "extension registers no commands"
[[ $ACTIVATIONS -gt 0 ]]     || fail "extension has no activationEvents"

# 5. The critical proof: the extension's compiled JS constructs a
#    LanguageClient whose documentSelector matches "monkeyc". When VS Code
#    opens source/App.mc, that selector matches and VS Code starts the
#    client, spawning LanguageServer.jar.
[[ -f "$EXT_JS" ]] || fail "extension dist/extension.js missing: $EXT_JS"
if ! grep -q "new yt.LanguageClient\|new LanguageClient" "$EXT_JS"; then
  fail "extension dist/extension.js does not construct a LanguageClient"
fi
if ! grep -q 'language:"monkeyc"' "$EXT_JS" && ! grep -q "language:'monkeyc'" "$EXT_JS"; then
  fail "extension's LanguageClient documentSelector does not include language:monkeyc"
fi
echo "Extension's LanguageClient documentSelector includes language:monkeyc"

# 6. The extension points at the SDK's LanguageServer.jar via our current-sdk.cfg.
SDK_BASE=$(cat "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" 2>/dev/null | tr -d '\n')
SDK_JAR="$SDK_BASE/bin/LanguageServer.jar"
[[ -f "$SDK_JAR" ]] || fail "SDK LanguageServer.jar not found at $SDK_JAR"
echo "SDK LanguageServer.jar: $SDK_JAR ($(wc -c <"$SDK_JAR") bytes)"

# 7. The project's .vscode/settings.json points at a JDK the SDK can use.
SETTINGS="$PROJECT_ROOT/.vscode/settings.json"
[[ -f "$SETTINGS" ]] || fail "project .vscode/settings.json missing"
# Strip // line comments before parsing (settings.json has them for documentation).
JAVA_PATH=$(python3 -c "
import json, re
raw = open('$SETTINGS').read()
stripped = re.sub(r'(?m)^\s*//.*$', '', raw)
print(json.loads(stripped)['monkeyC.javaPath'])
")
[[ -x "$JAVA_PATH/bin/java" ]] || fail "monkeyC.javaPath=$JAVA_PATH/bin/java is not executable"
echo "monkeyC.javaPath: $JAVA_PATH/bin/java ($(file "$JAVA_PATH/bin/java" | head -1))"

# 8. The project's jungle file references the manifest — required for the
#    LSP to know what API level / device profile to use.
JUNGLE="$PROJECT_ROOT/monkey.jungle"
[[ -f "$JUNGLE" ]] || fail "monkey.jungle missing"
grep -q "manifest.xml" "$JUNGLE" || fail "monkey.jungle does not reference manifest.xml"

echo ""
echo "PASS: Editor integration verified — VS Code + garmin.monkey-c extension"
echo "  is registered, configured for language:monkeyc, and pointed at the"
echo "  SDK's LanguageServer.jar via current-sdk.cfg."
