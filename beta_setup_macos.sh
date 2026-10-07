#!/usr/bin/env bash
set -euo pipefail

# Simple setup script for IvS ssh access on macOS
# This script:
# 0. checks all prerequisites at once and prints an overview of what is missing
# 1. asks for your r-number (or u- or b-number)
# 2. installs kmk from your Downloads folder and a helper command (kmkcheck) in ~/.local/bin
# 3. writes the kmk config
# 4. adds host entries for 's' and 'cluster' to ~/.ssh/config, plus defaults that
#    store key passphrases in the macOS Keychain and load keys into the agent on use
# 5. adds ~/.local/bin to PATH in your shell startup file (~/.zshrc or ~/.bash_profile)
#
# About the agent: macOS starts an ssh-agent for you (launchd) and every terminal
# uses it automatically, so no agent setup is needed. With 'UseKeychain yes' and
# 'AddKeysToAgent yes', you type a key's passphrase once; after that it comes from
# the Keychain and the key is loaded into the agent whenever ssh needs it.
#
# The script is safe to run again: files are only rewritten when their content
# changes, and the blocks it manages are replaced, never duplicated.
#
# Note: macOS ships bash 3.2, so this script avoids newer bash features.
#
# Environment variables:
#   LOG_LEVEL=3  show debug output
#   NO_COLOR=1   disable colored output


### Variables:
LOCAL_BIN="$HOME/.local/bin"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG_FILE="$SSH_DIR/config"
KMKCHECK_FILE="$LOCAL_BIN/kmkcheck"
KMK_DOWNLOAD="$HOME/Downloads/kmk"
KMK_URL="https://admin.kuleuven.be/icts/services/ssh-cert/kmk"

case "$(basename "${SHELL:-/bin/zsh}")" in
    bash) SHELL_RC="$HOME/.bash_profile" ;;
    *)    SHELL_RC="$HOME/.zshrc" ;;
esac

BLOCK_START="# >>> KU Leuven NS macOS SSH setup >>>"
BLOCK_END="# <<< KU Leuven NS macOS SSH setup <<<"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT


### Output functions
LOG_LEVEL=${LOG_LEVEL:-2}
# 0 = ERROR
# 1 = WARNING
# 2 = INFO
# 3 = DEBUG

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
    C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

if [ "$(locale charmap 2>/dev/null)" = "UTF-8" ]; then
    S_OK='✓' S_WARN='!' S_FAIL='✗' S_INFO='·'
else
    S_OK='+' S_WARN='!' S_FAIL='x' S_INFO='-'
fi

FAILURES=0
WARNINGS=0
CHANGED=0

heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
ok()      { printf '  %s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$*"; }
note()    { printf '  %s%s %s%s\n' "$C_DIM" "$S_INFO" "$*" "$C_RESET"; }
warn()    { printf '  %s%s%s %s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" "$*"; WARNINGS=$((WARNINGS + 1)); }
fail()    { printf '  %s%s%s %s\n' "$C_RED" "$S_FAIL" "$C_RESET" "$*"; FAILURES=$((FAILURES + 1)); }
hint()    { printf '      %s\n' "$*"; }
die()     { printf '\n%sError:%s %s\n' "$C_BOLD$C_RED" "$C_RESET" "$*" >&2; exit 1; }
debug()   { (( LOG_LEVEL < 3 )) || printf '%s[DEBUG] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

# Show a path with $HOME abbreviated to ~
pretty() {
    case "$1" in
        "$HOME"|"$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# report <result> <path>: print the outcome of writing a file
report() {
    local result=$1 label
    label="$(pretty "$2")"
    if [ "$result" = "unchanged" ]; then
        printf '  %s%s%s %-30s %sunchanged%s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$label" "$C_DIM" "$C_RESET"
    else
        printf '  %s%s%s %-30s %s%s%s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$label" "$C_BOLD" "$result" "$C_RESET"
        CHANGED=$((CHANGED + 1))
    fi
}


### File helpers
# install_file <src> <dest> [mode]: copy src to dest only if the content differs.
# Writes in place, so a symlinked dest (e.g. a dotfiles-managed rc file) stays a symlink.
# Sets RESULT to created, updated or unchanged.
install_file() {
    local src=$1 dest=$2 mode=${3:-}
    if [ -e "$dest" ] && cmp -s "$src" "$dest"; then
        RESULT=unchanged
    else
        if [ -e "$dest" ]; then RESULT=updated; else RESULT=created; fi
        cat -- "$src" > "$dest"
    fi
    if [ -n "$mode" ]; then chmod "$mode" "$dest"; fi
}

# markers_balanced <file>: true if every managed block start has a matching end
markers_balanced() {
    local starts ends
    [ -f "$1" ] || return 0
    starts="$(grep -cxF -- "$BLOCK_START" "$1" || true)"
    ends="$(grep -cxF -- "$BLOCK_END" "$1" || true)"
    [ "$starts" = "$ends" ]
}

# strip_block <file>: print file without the managed block and without trailing
# blank lines (so reruns don't keep adding blank lines)
strip_block() {
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
        $0 == start      { skip = 1; next }
        skip             { if ($0 == end) skip = 0; next }
        /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
                         { printf "%s", blanks; blanks = ""; print }
    ' "$1"
}

# block_value <file> <awk regex> <field>: print a field (0 = whole line) of the first
# matching line inside the managed block
block_value() {
    [ -f "$1" ] || return 0
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" -v re="$2" -v field="$3" '
        $0 == start         { inside = 1; next }
        $0 == end           { inside = 0; next }
        inside && $0 ~ re   { print $field; exit }
    ' "$1"
}

# write_managed_block <file> <block file> [mode]: replace the managed block in file
write_managed_block() {
    local file=$1 block=$2 mode=${3:-} tmp
    tmp="$WORK_DIR/$(basename "$file").new"
    : > "$tmp"
    if [ -f "$file" ]; then strip_block "$file" > "$tmp"; fi
    if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
    cat "$block" >> "$tmp"
    install_file "$tmp" "$file" "$mode"
}

# kmk_config_file: print the kmk config path (kmk may use ~/.config or ~/Library)
kmk_config_file() {
    local f
    for f in "${XDG_CONFIG_HOME:-$HOME/.config}/kmk/kmk.toml" \
             "$HOME/Library/Application Support/kmk/kmk.toml"; do
        if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
    done
}

# kmk_principals: print the principals currently set in the kmk config, if any
kmk_principals() {
    local f
    f="$(kmk_config_file)"
    [ -n "$f" ] || return 0
    awk -F'"' '/^[[:space:]]*principals[[:space:]]*=/ { print $2; exit }' "$f"
}

# binary_runs_here <file>: check a Mach-O binary matches this Mac's CPU.
# Prints a reason and returns 1 if it cannot run; returns 2 if it needs Rosetta.
binary_runs_here() {
    local desc cpu
    desc="$(file -b "$1" 2>/dev/null || true)"
    cpu="$(uname -m)"
    debug "file: $desc (cpu: $cpu)"
    case "$desc" in
        *Mach-O*) ;;
        *) printf 'not a macOS program (%s)' "${desc%%,*}"; return 1 ;;
    esac
    case "$desc" in *"$cpu"*) return 0 ;; esac
    if [ "$cpu" = "arm64" ] && [[ "$desc" == *x86_64* ]]; then
        return 2
    fi
    printf 'built for another CPU (this Mac is %s)' "$cpu"
    return 1
}


printf '%s=== KU Leuven NS SSH setup for macOS ===%s\n' "$C_BOLD" "$C_RESET"


### <<< 0. Checks >>>
# Run every check before changing anything, so all problems are reported at once.
heading "Checking prerequisites"

# macOS
if [ "$(uname -s)" = "Darwin" ]; then
    ok "macOS $(sw_vers -productVersion 2>/dev/null || true)"
else
    fail "This script is for macOS (this is $(uname -s))"
    hint "On Windows/WSL, use setup.sh instead."
fi

# Apple's OpenSSH (needed for the Keychain integration)
SSH_BIN="$(command -v ssh || true)"
if [ -z "$SSH_BIN" ]; then
    fail "ssh not found"
elif ssh -o UseKeychain=yes -G localhost >/dev/null 2>&1; then
    ok "ssh supports the macOS Keychain ($SSH_BIN)"
else
    warn "$SSH_BIN does not support the macOS Keychain (not Apple's ssh?)"
    hint "Key passphrases will not be stored in the Keychain with this ssh."
    hint "Apple's ssh is /usr/bin/ssh; a Homebrew openssh earlier in PATH hides it."
fi

# ssh-agent: launchd provides one for every terminal session
agent_rc=0
ssh-add -l >/dev/null 2>&1 || agent_rc=$?
debug "SSH_AUTH_SOCK = ${SSH_AUTH_SOCK:-} (ssh-add -l exit $agent_rc)"
if [ -z "${SSH_AUTH_SOCK:-}" ] || [ "$agent_rc" -eq 2 ]; then
    fail "No ssh-agent available in this terminal"
    hint "macOS normally starts one automatically. Check that your shell startup files"
    hint "do not unset or override SSH_AUTH_SOCK, then open a new terminal."
else
    ok "ssh-agent available"
    case "$SSH_AUTH_SOCK" in
        *com.apple.launchd*) ;;
        *) note "Using a non-default agent: $SSH_AUTH_SOCK" ;;
    esac
fi

# kmk
if [ -f "$LOCAL_BIN/kmk" ]; then
    KMK_SOURCE="$LOCAL_BIN/kmk"
    ok "kmk installed in $(pretty "$LOCAL_BIN")"
elif [ -f "$KMK_DOWNLOAD" ]; then
    KMK_SOURCE="$KMK_DOWNLOAD"
    ok "kmk found in your Downloads folder"
else
    KMK_SOURCE=""
    fail "kmk binary not found"
    hint "Download the macOS version from $KMK_URL"
    hint "and save it in your Downloads folder as 'kmk'."
fi
if [ -n "$KMK_SOURCE" ]; then
    arch_rc=0
    reason="$(binary_runs_here "$KMK_SOURCE")" || arch_rc=$?
    if [ "$arch_rc" -eq 1 ]; then
        fail "$(pretty "$KMK_SOURCE") is $reason"
        hint "Download the macOS version for your Mac from $KMK_URL"
    elif [ "$arch_rc" -eq 2 ]; then
        if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
            note "kmk is an Intel build; it will run through Rosetta"
        else
            fail "kmk is an Intel build and Rosetta is not installed"
            hint "Install Rosetta with: softwareupdate --install-rosetta"
            hint "or download the Apple silicon (arm64) version of kmk."
        fi
    fi
fi

# X11 forwarding to the cluster needs XQuartz; optional
if [ ! -x /opt/X11/bin/xauth ]; then
    note "XQuartz not installed: graphical programs on the cluster won't display (optional)"
fi

# Existing config files must not contain a half-removed managed block
for f in "$SSH_CONFIG_FILE" "$SHELL_RC"; do
    if ! markers_balanced "$f"; then
        fail "$(pretty "$f") has an incomplete '$BLOCK_START' block"
        hint "Remove the leftover '$BLOCK_START' / '$BLOCK_END' lines and run again."
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    printf '\n%s%d problem(s) found.%s Fix the items marked %s above, then run this script again.\n' \
        "$C_BOLD$C_RED" "$FAILURES" "$C_RESET" "$S_FAIL"
    printf 'Nothing has been changed yet.\n'
    exit 1
fi



### <<< 1. Ask u-number >>>
heading "KU Leuven account"
# Offer the username from a previous run (ssh config, else kmk config) as default
previous_user="$(block_value "$SSH_CONFIG_FILE" '^[[:space:]]*User[[:space:]]' 2)"
previous_user="${previous_user:-$(kmk_principals)}"
if [ -n "$previous_user" ]; then
    prompt="  Enter your KU Leuven username (r-number, u-number) [$previous_user]: "
else
    prompt="  Enter your KU Leuven username (r-number, u-number): "
fi
SSH_USER=""
read -r -p "$prompt" SSH_USER || true
SSH_USER="$(printf '%s' "$SSH_USER" | tr -d '[:space:]')"
SSH_USER="${SSH_USER:-$previous_user}"

if [ -z "$SSH_USER" ]; then
    die "No username entered. Nothing has been changed."
fi


heading "Configuring"

mkdir -p "$SSH_DIR" "$LOCAL_BIN"
chmod 700 "$SSH_DIR"



### <<< 2. Install kmk and helper script >>>
# Install kmk (only if missing; delete ~/.local/bin/kmk to reinstall from Downloads)
if [ "$KMK_SOURCE" = "$LOCAL_BIN/kmk" ]; then
    report unchanged "$LOCAL_BIN/kmk"
else
    install -m 0755 "$KMK_DOWNLOAD" "$LOCAL_BIN/kmk"
    report created "$LOCAL_BIN/kmk"
fi
# Files downloaded with a browser are quarantined by Gatekeeper and refuse to run
if xattr -p com.apple.quarantine "$LOCAL_BIN/kmk" >/dev/null 2>&1; then
    xattr -d com.apple.quarantine "$LOCAL_BIN/kmk"
    ok "Removed Gatekeeper quarantine from kmk"
fi

# kmkcheck: get a new certificate with kmk when there is none or it expired, then
# connect. macOS uses BSD date, hence 'date -j -f' instead of 'date -d'.
cat > "$WORK_DIR/kmkcheck" <<'EOF'
#!/usr/bin/env bash
trap 'trap - INT; kill -INT -- -$$' INT

ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "Error: No SSH agent running." >&2
  exit 1
fi

valid_until="$(ssh-add -L | grep cert | grep vaultssh | head -n1 | ssh-keygen -L -f /dev/stdin | grep Valid | awk '{print $5}')"
valid_until_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "$valid_until" +%s 2>/dev/null || echo 0)"
if [ -z "$valid_until" ] || [ "$(date +%s)" -gt "$valid_until_epoch" ]
then
  "$HOME/.local/bin/kmk"
fi

exec /usr/bin/nc "$1" "$2"
EOF

install_file "$WORK_DIR/kmkcheck" "$KMKCHECK_FILE" 755
report "$RESULT" "$KMKCHECK_FILE"



### <<< 3. kmk config >>>
# Only (re)write when principals differ. 'kmk config write' always exits 0, even on
# errors, so check the file itself afterwards. --overwrite keeps the other settings
# from the existing file and only replaces principals.
previous_principals="$(kmk_principals)"
if [ "$previous_principals" = "$SSH_USER" ]; then
    report unchanged "$(kmk_config_file)"
else
    kmk_output="$("$LOCAL_BIN/kmk" config write --overwrite --principals="$SSH_USER" 2>&1 || true)"
    debug "kmk output: $kmk_output"
    if [ "$(kmk_principals)" = "$SSH_USER" ]; then
        if [ -n "$previous_principals" ]; then result=updated; else result=created; fi
        report "$result" "$(kmk_config_file)"
    else
        warn "Could not set principals = \"$SSH_USER\" in the kmk config"
        hint "Run: kmk config write --overwrite --principals=$SSH_USER"
    fi
fi



### <<< 4. ssh config >>>
# 'Host *' comes last so your own settings earlier in the file take precedence.
# IgnoreUnknown keeps the config working with a non-Apple ssh (e.g. Homebrew).
cat > "$WORK_DIR/ssh_block" <<EOF
$BLOCK_START
host s s.fys.kuleuven.be
  HostName s.fys.kuleuven.be
  User $SSH_USER
  ForwardAgent yes
  ServerAliveInterval 240
  proxycommand ~/.local/bin/kmkcheck %h %p
Host cluster cluster-last cluster.fys.kuleuven.be cluster-last.fys.kuleuven.be
  ProxyCommand ssh %r@s /usr/bin/ballast-login %h
  User $SSH_USER
  ForwardAgent yes
  ForwardX11 yes
  ServerAliveInterval 240
  HostKeyAlias cluster.fys.kuleuven.be
# Store key passphrases in the macOS Keychain and load keys into the agent on first use
Host *
  IgnoreUnknown UseKeychain
  UseKeychain yes
  AddKeysToAgent yes
$BLOCK_END
EOF

write_managed_block "$SSH_CONFIG_FILE" "$WORK_DIR/ssh_block" 600
report "$RESULT" "$SSH_CONFIG_FILE"

# Make sure ssh accepts the resulting config
if ssh_err="$(ssh -G s 2>&1 >/dev/null)"; then
    ok "ssh config is valid"
else
    warn "ssh reports a problem in $(pretty "$SSH_CONFIG_FILE"):"
    hint "$ssh_err"
fi



### <<< 5. PATH in shell startup file >>>
cat > "$WORK_DIR/rc_block" <<EOF
$BLOCK_START
# Make sure ~/.local/bin (kmk, kmkcheck) is on PATH
case ":\$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) export PATH="$LOCAL_BIN:\$PATH" ;;
esac
$BLOCK_END
EOF

write_managed_block "$SHELL_RC" "$WORK_DIR/rc_block"
RC_RESULT=$RESULT
report "$RESULT" "$SHELL_RC"



### <<< Summary >>>
heading "Summary"
if [ "$CHANGED" -eq 0 ]; then
    ok "Everything was already up to date. Nothing changed."
else
    ok "$CHANGED file(s) created or updated."
fi
if [ "$WARNINGS" -gt 0 ]; then
    warn "$WARNINGS warning(s) above, please check them."
fi

if [ "$RC_RESULT" != "unchanged" ]; then
    printf '\nOpen a new terminal to activate these changes.\n'
fi
printf '\nConnect with: %sssh s%s or %sssh cluster%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
printf 'The first connection opens kmk to get your certificate.\n'
