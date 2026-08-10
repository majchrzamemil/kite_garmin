# Environment Setup Notes

This document records environment changes made during the project setup that
live **outside** the repo. Each section includes what was done, why, and the
exact command to undo it.

> ⚠️ These changes affect your global macOS environment. Review before
> applying to a different machine.

---

## 1. Java 11+

**Installed**: Homebrew `openjdk@17` 17.0.20.

```
brew install openjdk@17
brew link --force openjdk@17
```

If `brew link` failed (Apple Silicon), Homebrew prints the exact
`sudo ln -s …` commands needed to expose the binaries on `/usr/local/bin` or
`/opt/homebrew/bin`.

**Symlink in PATH**: `/opt/homebrew/bin/java` → `/opt/homebrew/opt/openjdk@17/bin/java`.

**Verify**: `java -version` should print `openjdk version "17.0.x"`.

**Rollback**: `brew uninstall openjdk@17` (removes the keg and the link).

---

## 2. Connect IQ SDK

**Installed**: `brew install --cask connectiq` (Homebrew SDK 9.2.0).

The cask installs:

- The SDK at `/opt/homebrew/Caskroom/connectiq/9.2.0,<date>/…/`.
- A `ConnectIQ.app` Simulator bundle at `/Applications/ConnectIQ.app`.

After install, the SDK Manager (separate cask
`brew install --cask connectiq-sdk-manager`) downloaded **168 device profiles**
into `~/Library/Application Support/Garmin/ConnectIQ/Devices/`.

`monkeyc`, `monkeydo`, `monkeydoc`, `connectiq` are symlinked into
`/opt/homebrew/bin/`.

**Verify**: `monkeyc --version` should print `Connect IQ Compiler version: 9.2.0`.

**Rollback**:

```
brew uninstall --cask connectiq connectiq-sdk-manager
rm -rf ~/Library/Application\ Support/Garmin/ConnectIQ/Devices/
```

---

## 3. `/Applications/ConnectIQ.app` symlink

**Why**: The Simulator bundle installed by the brew cask searches for
`version.txt` in `/Applications/` (relative to its own path). That file
doesn't exist there in the brew cask layout, and the Simulator emits
`Can't open file '/Applications/version.txt'` errors.

**What was done**: replaced the cask-installed `/Applications/ConnectIQ.app`
with a **symlink** to the SDK Manager's copy at
`~/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-<date>/bin/ConnectIQ.app`.

```
rm -rf /Applications/ConnectIQ.app
ln -s "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2/bin/ConnectIQ.app" /Applications/ConnectIQ.app
```

**Rollback** (restores the cask's original bundle):

```
rm /Applications/ConnectIQ.app
brew reinstall --cask connectiq
```

---

## 4. `/Applications/version.txt`

**Why**: Even with the symlink, the Simulator still emits warnings about
`/Applications/version.txt`. Dropping a small file there silences it.

**What was done**: `cp $SDK/bin/version.txt /Applications/version.txt`
where `$SDK` is the brew-cask SDK path. File contents: `9.2.0` (6 bytes).

**Verify**: `cat /Applications/version.txt` prints `9.2.0`.

**Rollback**: `rm /Applications/version.txt`.

---

## 5. `/opt/homebrew/bin/monkeyc` — auto-key wrapper

**Why**: Connect IQ SDK 9.x requires `-y <private_key>` for **every** `.prg`
build (including simulator builds). The error message says
"`Use command line option: -y`" with no autodiscovery hint. Forgetting `-y`
breaks every IDE "build" button press.

**What was done**: replaced the symlink at `/opt/homebrew/bin/monkeyc` (which
pointed at `$SDK/bin/monkeyc`) with a small bash wrapper that auto-injects
`-y ~/.Garmin/connect_iq_dev_key.der` when `-o` (build) is passed. Other
invocations (`--version`, `--help`) pass through unmodified.

**File contents**:

```bash
#!/bin/bash
# Auto-key wrapper for the Connect IQ SDK monkeyc.
# SDK 9.x requires -y <private_key> for every .prg build.
set -euo pipefail

REAL=/opt/homebrew/Caskroom/connectiq/9.2.0,2026-06-09,92a1605b2/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2/bin/monkeyc
DEFAULT_KEY="$HOME/.Garmin/connect_iq_dev_key.der"

case "${1:-}" in
  -h|--help|-v|--version) exec "$REAL" "$@" ;;
esac

seen_y=0; seen_o=0
for arg in "$@"; do
  case "$arg" in -y) seen_y=1 ;; -o|--output) seen_o=1 ;; esac
done

if [[ $seen_o -eq 1 && $seen_y -eq 0 && -s "$DEFAULT_KEY" ]]; then
  OUT=()
  injected=0
  for arg in "$@"; do
    if [[ $injected -eq 0 && ( "$arg" == "-o" || "$arg" == "--output" ) ]]; then
      OUT+=(-y "$DEFAULT_KEY")
      injected=1
    fi
    OUT+=("$arg")
  done
  exec "$REAL" "${OUT[@]}"
fi

exec "$REAL" "$@"
```

**Behavior**:

- `monkeyc -o foo.prg -d instinct2 -f monkey.jungle` → auto-injects `-y`.
- `monkeyc --version` → passes through (returns `Connect IQ Compiler version: 9.2.0`).
- `monkeyc -y /custom/key.der -o foo.prg -d instinct2 -f monkey.jungle` → leaves your key alone.
- If `~/.Garmin/connect_iq_dev_key.der` is missing, the wrapper falls through
  to the real monkeyc, which will print the standard "private key was not specified" error.

**Rollback** (restores the symlink to the real SDK monkeyc):

```
rm /opt/homebrew/bin/monkeyc
ln -s /opt/homebrew/Caskroom/connectiq/9.2.0,2026-06-09,92a1605b2/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2/bin/monkeyc /opt/homebrew/bin/monkeyc
```

---

## 6. Developer signing key

**What was done**: generated via VS Code's "Monkey C: Generate a Developer Key"
command (which authenticates against `sso.garmin.com` and writes the DER-encoded
private key to disk). Moved to the SDK's expected location.

```
mkdir -p ~/.Garmin
mv ~/Downloads/developer_key ~/.Garmin/connect_iq_dev_key.der
```

**Verify**: `test -s ~/.Garmin/connect_iq_dev_key.der && echo OK`.

**Rollback**: `rm ~/.Garmin/connect_iq_dev_key.der` (you'll need to re-generate
via the same VS Code flow to build again).

**DO NOT COMMIT** — the `.gitignore` excludes `*.der` and `.Garmin/` already.

---

## 7. Editor — VS Code (pivoted from Neovim)

**Why this is different from the original plan**: the plan called for
`bombsimon/garmin-monkeyc.nvim` in Neovim. During setup, Visual Studio Code
was installed to access Garmin's "Monkey C: Generate a Developer Key"
command (which is exclusive to the official VS Code extension). The user
chose to keep VS Code as the editor instead of also installing Neovim.

**What was installed**: `Visual Studio Code 1.130.0` and the
`garmin.monkey-c` extension v1.1.3 (also via the brew cask or the
Extensions tab in VS Code).

**`.vscode/settings.json`** (already in the repo):

```json
{
  "monkeyC.javaPath": "/opt/homebrew/opt/openjdk@17",
  "monkeyC.jungleFiles": "monkey.jungle",
  "monkeyC.developerKeyPath": "/Users/em/.Garmin/connect_iq_dev_key.der"
}
```

**Verify**:

- `code --version` returns `1.130.0`.
- `~/.vscode/extensions/garmin.monkey-c-1.1.3/package.json` shows
  `displayName: "Monkey C"`, `publisher: "Garmin"`.
- LSP attached: `LanguageServer.jar` at
  `~/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.2.0-2026-06-09-92a1605b2/bin/LanguageServer.jar`
  receives a `textDocument/didOpen` for `source/App.mc` (verified via direct
  JSON-RPC test — see `verification/lsp_attach_proof.sh` in the repo).

**Rollback** (if you want to switch back to Neovim per the original plan):

```
brew uninstall --cask visual-studio-code
rm -rf ~/.vscode
# Then install Neovim + the bombsimon plugin
brew install neovim
# Add to your Neovim config (lazy.nvim):
# { "bombsimon/garmin-monkeyc.nvim", config = function() require("garmin-monkeyc").setup({}) end }
```

---

## Quick verification script

```bash
#!/bin/bash
set -e
java -version 2>&1 | grep -qE '17\.'          && echo "java 17+   OK"
monkeyc --version | grep -qE '9\.2\.0'        && echo "SDK 9.2.0  OK"
test -s ~/.Garmin/connect_iq_dev_key.der      && echo "key        OK"
ls /Applications/ConnectIQ.app                && echo "Simulator  OK"
test -f /Applications/version.txt             && echo "version.txt OK"
ls ~/.vscode/extensions/garmin.monkey-c-*     && echo "VS Code ext OK"
```
