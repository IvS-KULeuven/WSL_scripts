#!/usr/bin/env bash
set -euo pipefail

# Simple setup script for IvS ssh access on Linux (bash)
# This script:
# 0. checks all prerequisites at once and prints an overview of what is missing
# 1. asks for your r-number (or u- or b-number)
# 2. installs kmk from your Downloads folder and a helper command (kmkcheck) in ~/.local/bin
# 3. writes the kmk config
# 4. adds host entries for 's' and 'cluster' to ~/.ssh/config, plus a default that
#    loads keys into the agent on first use
# 5. sets up ~/.bashrc: ~/.local/bin on PATH, and an ssh-agent in every shell
#
# About the agent: most Linux desktops (GNOME, KDE, ...) already provide an ssh-agent.
# The ~/.bashrc block uses that one when it works. Otherwise (console, ssh login,
# minimal desktop) it starts one agent on ~/.ssh/agent.sock that all your shells share.
# With 'AddKeysToAgent yes' you type a key's passphrase once per agent session.
#
# Only bash is supported. With another login shell the script still runs, but you
# need to copy the ~/.bashrc block to your own shell's startup file.
#
# The script is safe to run again: files are only rewritten when their content
# changes, and the blocks it manages are replaced, never duplicated.
#
# Environment variables:
#   LOG_LEVEL=3  show debug output
#   NO_COLOR=1   disable colored output


### Variables:
LOCAL_BIN="$HOME/.local/bin"
BASHRC="$HOME/.bashrc"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG_FILE="$SSH_DIR/config"
KMKCHECK_FILE="$LOCAL_BIN/kmkcheck"
KMK_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kmk/kmk.toml"
KMK_URL="https://w.fys.kuleuven.be/public/deploy/$(uname -s)/kmk/kmk-$(uname -m)-latest"

BLOCK_START="# >>> KU Leuven NS Linux SSH setup >>>"
BLOCK_END="# <<< KU Leuven NS Linux SSH setup <<<"

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
pretty() { printf '%s' "${1/#$HOME/\~}"; }

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
# Writes in place, so a symlinked dest (e.g. a dotfiles-managed .bashrc) stays a symlink.
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

# kmk_principals: print the principals currently set in the kmk config, if any
kmk_principals() {
    [ -f "$KMK_CONFIG_FILE" ] || return 0
    awk -F'"' '/^[[:space:]]*principals[[:space:]]*=/ { print $2; exit }' "$KMK_CONFIG_FILE"
}

# find_kmk <dir>...: print the kmk download to install, if any. Preferred: the download
# for this CPU (kmk-<arch>-latest, incl. browser copies like 'kmk-x86_64-latest (1)'),
# then a file already renamed to 'kmk', then any other kmk-* file. The newest file wins
# within each of these. Partial downloads are skipped.
find_kmk() {
    local pattern dir f newest
    for pattern in "kmk-$(uname -m)-latest*" "kmk" "kmk-*"; do
        newest=""
        for dir in "$@"; do
            for f in "$dir"/$pattern; do
                [ -f "$f" ] || continue
                case "$f" in *.crdownload|*.part|*.download|*.tmp) continue ;; esac
                if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
            done
        done
        if [ -n "$newest" ]; then printf '%s' "$newest"; return 0; fi
    done
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

# package_for <command>: print the package providing a command on this distro
package_for() {
    case "$PKG_MANAGER:$1" in
        apt:nc)     echo netcat-openbsd ;;
        dnf:nc)     echo nmap-ncat ;;
        pacman:nc)  echo openbsd-netcat ;;
        zypper:nc)  echo netcat-openbsd ;;
        apt:ssh*)   echo openssh-client ;;
        pacman:ssh*) echo openssh ;;
        *:ssh*)     echo openssh-clients ;;
        *:awk)      echo gawk ;;
        *)          echo "$1" ;;
    esac
}


printf '%s=== KU Leuven NS SSH setup for Linux ===%s\n' "$C_BOLD" "$C_RESET"


### <<< 0. Checks >>>
# Run every check before changing anything, so all problems are reported at once.
heading "Checking prerequisites"

# Linux, but not WSL (that needs the Windows agent, see setup_WSL.sh)
if [ "$(uname -s)" != "Linux" ]; then
    fail "This script is for Linux (this is $(uname -s))"
    hint "On macOS, use beta_setup_macos.sh instead."
elif [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    fail "This is WSL on Windows"
    hint "Use setup_WSL.sh instead: it connects WSL to CertAgent on Windows."
else
    distro="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")" || distro=""
    ok "Linux${distro:+ ($distro)}"
fi

# Login shell: only bash is configured
login_shell="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)" || login_shell=""
login_shell="$(basename "${login_shell:-${SHELL:-/bin/bash}}")"
if [ "$login_shell" = "bash" ]; then
    ok "Login shell is bash"
else
    warn "Your login shell is $login_shell; this script only configures bash"
    hint "Copy the block between the '$BLOCK_START' markers in ~/.bashrc"
    hint "to your shell's startup file (it sets PATH and starts an ssh-agent)."
fi

# Required commands
PKG_MANAGER=""
for pm in apt dnf pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then PKG_MANAGER=$pm; break; fi
done
missing_packages=""
for cmd in nc awk ssh ssh-add ssh-agent ssh-keygen; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        pkg="$(package_for "$cmd")"
        case " $missing_packages " in *" $pkg "*) ;; *) missing_packages="${missing_packages:+$missing_packages }$pkg" ;; esac
    fi
done
if [ -z "$missing_packages" ]; then
    ok "Required programs (nc, awk, ssh tools)"
else
    fail "Missing packages: $missing_packages"
    case "$PKG_MANAGER" in
        apt)    hint "Install them with: sudo apt update && sudo apt install -y $missing_packages" ;;
        dnf)    hint "Install them with: sudo dnf install -y $missing_packages" ;;
        pacman) hint "Install them with: sudo pacman -S --needed $missing_packages" ;;
        zypper) hint "Install them with: sudo zypper install $missing_packages" ;;
        *)      hint "Install them with your distribution's package manager." ;;
    esac
fi

# kmk: installed, or downloaded in the Downloads folder (which may have a localized
# name; any download name, see find_kmk)
DOWNLOAD_DIR="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
if [ -z "$DOWNLOAD_DIR" ] || [ "$DOWNLOAD_DIR" = "$HOME" ]; then DOWNLOAD_DIR="$HOME/Downloads"; fi
if [ -f "$LOCAL_BIN/kmk" ]; then
    KMK_SOURCE="$LOCAL_BIN/kmk"
elif [ "$DOWNLOAD_DIR" = "$HOME/Downloads" ]; then
    KMK_SOURCE="$(find_kmk "$DOWNLOAD_DIR")"
else
    KMK_SOURCE="$(find_kmk "$DOWNLOAD_DIR" "$HOME/Downloads")"
fi
if [ -z "$KMK_SOURCE" ]; then
    fail "kmk binary not found"
    hint "Download the Linux version from $KMK_URL"
    hint "and save it in your Downloads folder ($(pretty "$DOWNLOAD_DIR"))."
else
    # Make sure it actually runs here (e.g. not a macOS or wrong-CPU build)
    install -m 0755 "$KMK_SOURCE" "$WORK_DIR/kmk"
    if "$WORK_DIR/kmk" --help >/dev/null 2>&1; then
        if [ "$KMK_SOURCE" = "$LOCAL_BIN/kmk" ]; then
            ok "kmk installed in $(pretty "$LOCAL_BIN")"
        else
            ok "kmk found: $(pretty "$KMK_SOURCE")"
        fi
    else
        fail "$(pretty "$KMK_SOURCE") does not run on this system ($(uname -m))"
        hint "Download the Linux version for your CPU from $KMK_URL"
    fi
fi

# ssh-agent: informational, the ~/.bashrc block takes care of it
agent_rc=0
ssh-add -l >/dev/null 2>&1 || agent_rc=$?
debug "SSH_AUTH_SOCK = ${SSH_AUTH_SOCK:-} (ssh-add -l exit $agent_rc)"
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ "$agent_rc" -ne 2 ]; then
    ok "ssh-agent available ($(pretty "$SSH_AUTH_SOCK"))"
else
    note "No ssh-agent in this terminal; ~/.bashrc will start one for new shells"
fi

# Existing config files must not contain a half-removed managed block
for f in "$SSH_CONFIG_FILE" "$BASHRC"; do
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
SSH_USER="${SSH_USER//[[:space:]]/}"
SSH_USER="${SSH_USER:-$previous_user}"

if [ -z "$SSH_USER" ]; then
    die "No username entered. Nothing has been changed."
fi


heading "Configuring"

mkdir -p "$SSH_DIR" "$LOCAL_BIN"
chmod 700 "$SSH_DIR"



### <<< 2. Install kmk and helper script >>>
# Install kmk as ~/.local/bin/kmk, whatever the download is called (only if missing;
# delete ~/.local/bin/kmk to reinstall from Downloads)
if [ "$KMK_SOURCE" = "$LOCAL_BIN/kmk" ]; then
    report unchanged "$LOCAL_BIN/kmk"
else
    install -m 0755 "$KMK_SOURCE" "$LOCAL_BIN/kmk"
    report created "$LOCAL_BIN/kmk"
fi

# kmkcheck: get a new certificate with kmk when there is none or it expired, then connect
cat > "$WORK_DIR/kmkcheck" <<'EOF'
#!/usr/bin/env bash
trap 'trap - INT; kill -INT -- -$$' INT

ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "Error: No SSH agent running." >&2
  exit 1
fi

valid_until="$(ssh-add -L | grep cert | grep vaultssh | head -n1 | ssh-keygen -L -f /dev/stdin | grep Valid | awk '{print $5}')"
if [ -z "$valid_until" ] || [ "$(date +%s)" -gt "$(date -d "$valid_until" +%s)" ]
then
  "$HOME/.local/bin/kmk"
fi

exec nc "$1" "$2"
EOF

install_file "$WORK_DIR/kmkcheck" "$KMKCHECK_FILE" 755
report "$RESULT" "$KMKCHECK_FILE"



### <<< 3. kmk config >>>
# Only (re)write when principals differ. 'kmk config write' always exits 0, even on
# errors, so check the file itself afterwards. --overwrite keeps the other settings
# from the existing file and only replaces principals.
previous_principals="$(kmk_principals)"
if [ "$previous_principals" = "$SSH_USER" ]; then
    report unchanged "$KMK_CONFIG_FILE"
else
    kmk_output="$("$LOCAL_BIN/kmk" config write --overwrite --principals="$SSH_USER" 2>&1 || true)"
    debug "kmk output: $kmk_output"
    if [ "$(kmk_principals)" = "$SSH_USER" ]; then
        if [ -n "$previous_principals" ]; then report updated "$KMK_CONFIG_FILE"; else report created "$KMK_CONFIG_FILE"; fi
    else
        warn "Could not set principals = \"$SSH_USER\" in $(pretty "$KMK_CONFIG_FILE")"
        hint "Run: kmk config write --overwrite --principals=$SSH_USER"
    fi
fi



### <<< 4. ssh config >>>
# 'Host *' comes last so your own settings earlier in the file take precedence.
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
# Load keys into the agent on first use, so you type a passphrase only once
Host *
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



### <<< 5. .bashrc >>>
# Create $BASHRC if the file does not exist
if [ ! -f "$BASHRC" ] && [ -f /etc/skel/.bashrc ]; then
    debug "No $BASHRC found, copying from skel"
    install -m 0644 /etc/skel/.bashrc "$BASHRC"
fi

cat > "$WORK_DIR/bashrc_block" <<EOF
$BLOCK_START
# Make sure ~/.local/bin (kmk, kmkcheck) is on PATH
case ":\$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) export PATH="$LOCAL_BIN:\$PATH" ;;
esac
EOF
cat >> "$WORK_DIR/bashrc_block" <<'EOF'

# Use the desktop's ssh-agent if it works; otherwise share one agent between all
# shells on ~/.ssh/agent.sock, starting it when it is not running yet.
_agent_ok() { ssh-add -l >/dev/null 2>&1; [ $? -ne 2 ]; }
if ! _agent_ok; then
  export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
  if ! _agent_ok; then
    rm -f -- "$SSH_AUTH_SOCK"
    ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null
  fi
fi
unset -f _agent_ok
EOF
printf '%s\n' "$BLOCK_END" >> "$WORK_DIR/bashrc_block"

write_managed_block "$BASHRC" "$WORK_DIR/bashrc_block"
BASHRC_RESULT=$RESULT
report "$RESULT" "$BASHRC"



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

if [ "$BASHRC_RESULT" != "unchanged" ]; then
    printf '\nOpen a new terminal to activate these changes.\n'
fi
printf '\nConnect with: %sssh s%s or %sssh cluster%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
printf 'The first connection runs kmk to get your certificate.\n'
