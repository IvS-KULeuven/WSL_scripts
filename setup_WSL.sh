#!/usr/bin/env bash
set -euo pipefail

# Simple setup script for IvS ssh access on WSL Ubuntu
# This script:
# 0. checks all prerequisites at once and prints an overview of what is missing
# 1. asks for your r-number (or u- or b-number)
# 2. creates ~/.ssh/config if needed
# 3. adds host entries to ~/.ssh/config, and to C:\Users\<you>\.ssh\config for ssh in
#    PowerShell/CMD (there without kmkcheck: Windows ssh talks to CertAgent directly)
# 4. installs kmk and a helper command (kmkcheck) in ~/.local/bin
# 5. downloads npiperelay to communicate with Windows CertAgent
# 6. sets up the necessary config in ~/.bashrc (incl. ~/.local/bin on PATH)
# 7. optionally loads SSH keys from your Windows .ssh folder at every WSL start
#    (see --keys below)
#
# About SSH keys: WSL uses the Windows agent (CertAgent) through npiperelay, so any
# key you add on Windows (ssh-add in PowerShell or CMD) is also available in WSL.
# CertAgent does not keep keys after a restart, and WSL cannot use the key files in
# C:\Users\<you>\.ssh directly (file permissions). With --keys, selected keys are
# cached in ~/.ssh/.windows-cached-keys and loaded into the agent whenever a WSL
# shell starts. The cache follows Windows: changed keys are copied again, and keys
# deleted on Windows are removed from the cache.
#
# Usage: setup_WSL.sh [--keys "KEY ..."] [--no-keys] [-h|--help]
#
# The script is safe to run again: files are only rewritten when their content
# changes, and the blocks it manages in ~/.ssh/config and ~/.bashrc are replaced,
# never duplicated.
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
KEY_CACHE_DIR="$SSH_DIR/.windows-cached-keys"
OLD_KEY_CACHE_DIR="$SSH_DIR/.windows"
KMK_URL="https://w.fys.kuleuven.be/public/deploy/$(uname -s)/kmk/kmk-$(uname -m)-latest"
CERTAGENT_URL="https://admin.kuleuven.be/icts/services/ssh-cert/certagent_installer-0-20-0.exe"
NPIPERELAY_URL="https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip"

BLOCK_START="# >>> KU Leuven NS WSL SSH setup >>>"
BLOCK_END="# <<< KU Leuven NS WSL SSH setup <<<"
# Older versions of this script added a separate PATH snippet starting with this line
OLD_PATH_MARKER="# Added by KU Leuven NS WSL SSH setup"

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
    S_OK='✓' S_WARN='!' S_FAIL='✗'
else
    S_OK='+' S_WARN='!' S_FAIL='x'
fi

FAILURES=0
WARNINGS=0
CHANGED=0

heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
ok()      { printf '  %s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$*"; }
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
# (\r is ignored, so this also works for Windows files with CRLF line endings)
markers_balanced() {
    local starts ends
    [ -f "$1" ] || return 0
    starts="$(tr -d '\r' < "$1" | grep -cxF -- "$BLOCK_START" || true)"
    ends="$(tr -d '\r' < "$1" | grep -cxF -- "$BLOCK_END" || true)"
    [ "$starts" = "$ends" ]
}

# strip_block <file>: print file without the managed block, without the legacy PATH
# snippet and without trailing blank lines (so reruns don't keep adding blank lines).
# CRLF line endings are converted to LF.
strip_block() {
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" -v old="$OLD_PATH_MARKER" '
                         { sub(/\r$/, "") }
        $0 == start      { skip = 1; next }
        skip             { if ($0 == end) skip = 0; next }
        $0 == old        { legacy = 3; next }
        legacy > 0       { legacy--; next }
        /^[[:space:]]*$/ { blanks = blanks $0 "\n"; next }
                         { printf "%s", blanks; blanks = ""; print }
    ' "$1"
}

# block_value <file> <awk regex> <field>: print a field (0 = whole line) of the first
# matching line inside the managed block
block_value() {
    [ -f "$1" ] || return 0
    awk -v start="$BLOCK_START" -v end="$BLOCK_END" -v re="$2" -v field="$3" '
                            { sub(/\r$/, "") }
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

# write_managed_block <file> <block file> [mode]: replace the managed block in file.
# A file with CRLF line endings keeps them.
write_managed_block() {
    local file=$1 block=$2 mode=${3:-} tmp
    tmp="$WORK_DIR/$(basename "$(dirname "$file")")_$(basename "$file").new"
    : > "$tmp"
    if [ -f "$file" ]; then strip_block "$file" > "$tmp"; fi
    if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
    cat "$block" >> "$tmp"
    if [ -f "$file" ] && grep -q $'\r' "$file"; then sed -i 's/$/\r/' "$tmp"; fi
    install_file "$tmp" "$file" "$mode"
}

# other_host_entries <file>: print the s/cluster host names that already have a Host
# entry outside the managed block. ssh uses the first value it finds for each option,
# so those entries take precedence over the managed block at the end of the file.
other_host_entries() {
    [ -f "$1" ] || return 0
    strip_block "$1" | awk '
        tolower($1) == "host" {
            for (i = 2; i <= NF; i++)
                if ($i ~ /^(s|cluster|cluster-last)(\.fys\.kuleuven\.be)?$/) print $i
        }' | sort -u | tr '\n' ' ' | sed 's/ $//'
}


### Arguments
usage() {
    cat <<'EOF'
Usage: setup_WSL.sh [--keys "KEY ..."] [--no-keys] [-h|--help]

  --keys "KEY ..."  Load these keys from your Windows .ssh folder (C:\Users\<you>\.ssh)
                    into the agent at every WSL start. Space separated file names,
                    e.g. --keys "id_rsa id_ecdsa".
  --no-keys         Stop loading Windows keys at WSL start.
  -h, --help        Show this help.

Without --keys or --no-keys, the keys chosen in a previous run are kept.
EOF
}

KEYS_MODE=keep   # keep | set | none
KEYS_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --keys)
            if [ $# -lt 2 ]; then usage >&2; exit 2; fi
            KEYS_MODE=set; KEYS_ARG=$2; shift 2 ;;
        --keys=*)  KEYS_MODE=set; KEYS_ARG=${1#*=}; shift ;;
        --no-keys) KEYS_MODE=none; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ "$KEYS_MODE" = "set" ] && [ -z "${KEYS_ARG//[[:space:],]/}" ]; then
    KEYS_MODE=none
fi


printf '%s=== KU Leuven NS SSH setup for WSL Ubuntu ===%s\n' "$C_BOLD" "$C_RESET"


### <<< 0. Checks >>>
# Run every check before changing anything, so all problems are reported at once.
heading "Checking prerequisites"

# Windows interop
WIN_USER="$(cmd.exe /c "echo %USERNAME%" </dev/null 2>/dev/null | tr -d '\r')" || WIN_USER=""
WIN_HOME="/mnt/c/Users/$WIN_USER"
debug "Windows user = $WIN_USER"
if [ -n "$WIN_USER" ] && [ -d "$WIN_HOME" ]; then
    ok "Windows interop (Windows user: $WIN_USER)"
else
    fail "Cannot reach Windows from WSL"
    hint "Could not run cmd.exe or find your Windows home folder."
    hint "Make sure Windows interop is enabled in WSL and C: is mounted at /mnt/c."
    WIN_USER=""
fi

# Ubuntu packages
missing_packages=()
need() { command -v "$1" >/dev/null 2>&1 || missing_packages+=("$2"); }
need nc     netcat-openbsd
need awk    gawk
need socat  socat
need curl   curl
need unzip  unzip
need ssh    openssh-client
need ps     procps

if [ "${#missing_packages[@]}" -eq 0 ]; then
    ok "Required Ubuntu packages"
else
    fail "Missing Ubuntu packages: ${missing_packages[*]}"
    hint "Install them with:"
    hint "  sudo apt update && sudo apt install -y ${missing_packages[*]}"
fi

# kmk: installed, or downloaded in the Windows Downloads folder (any name, see find_kmk)
KMK_SOURCE=""
if [ -f "$LOCAL_BIN/kmk" ]; then
    KMK_SOURCE="$LOCAL_BIN/kmk"
elif [ -n "$WIN_USER" ]; then
    KMK_SOURCE="$(find_kmk "$WIN_HOME/Downloads")"
fi
if [ -n "$KMK_SOURCE" ]; then
    # Make sure it actually runs here (e.g. not a macOS or wrong-CPU build)
    install -m 0755 "$KMK_SOURCE" "$WORK_DIR/kmk"
    if "$WORK_DIR/kmk" --help >/dev/null 2>&1; then
        if [ "$KMK_SOURCE" = "$LOCAL_BIN/kmk" ]; then
            ok "kmk installed in $(pretty "$LOCAL_BIN")"
        else
            ok "kmk found in your Windows Downloads folder ($(basename "$KMK_SOURCE"))"
        fi
    else
        fail "$(basename "$KMK_SOURCE") in your Windows Downloads folder does not run in WSL"
        hint "Download the Linux version from $KMK_URL"
        hint "and save it in your Windows Downloads folder (C:\\Users\\$WIN_USER\\Downloads)."
    fi
elif [ -n "$WIN_USER" ]; then
    fail "kmk binary not found"
    hint "Download it from $KMK_URL"
    hint "and save it in your Windows Downloads folder (C:\\Users\\$WIN_USER\\Downloads)."
else
    fail "kmk binary not found (cannot look in your Windows Downloads folder)"
fi

# CertAgent
if [ -n "$WIN_USER" ]; then
    certagent_installed=0
    for exe in "/mnt/c/Program Files/CertAgent/certagent.exe" \
               "$WIN_HOME/AppData/Local/Programs/CertAgent/certagent.exe"; do
        if [ -f "$exe" ]; then certagent_installed=1; fi
    done

    certagent_running=0
    tasks="$(tasklist.exe /FI "IMAGENAME eq certagent.exe" /NH </dev/null 2>/dev/null || true)"
    if [[ "${tasks,,}" == *certagent.exe* ]]; then
        certagent_running=1
        certagent_installed=1
    fi

    certagent_autostart=0
    for lnk in "$WIN_HOME/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/CertAgent.lnk" \
               "/mnt/c/ProgramData/Microsoft/Windows/Start Menu/Programs/StartUp/CertAgent.lnk"; do
        if [ -f "$lnk" ]; then certagent_autostart=1; fi
    done
    debug "CertAgent installed=$certagent_installed running=$certagent_running autostart=$certagent_autostart"

    if [ "$certagent_installed" -eq 0 ]; then
        fail "CertAgent is not installed on Windows"
        hint "Install it from $CERTAGENT_URL"
        hint "and set it to autostart (right-click the tray icon -> AutoStart)."
    else
        ok "CertAgent installed"
        if [ "$certagent_running" -eq 1 ]; then
            ok "CertAgent running"
        else
            warn "CertAgent is not running"
            hint "Start CertAgent from the Windows Start menu."
        fi
        if [ "$certagent_autostart" -eq 1 ]; then
            ok "CertAgent starts automatically"
        else
            warn "CertAgent does not seem to start automatically"
            hint "Right-click the CertAgent icon in the Windows tray and check AutoStart."
        fi
    fi
else
    fail "CertAgent not checked (needs Windows interop)"
fi

# The OpenSSH Authentication Agent service that comes with Windows serves the same pipe
# as CertAgent (\\.\pipe\openssh-ssh-agent), so only one of them can run. Field names
# and numeric codes in the sc.exe output are not translated; 1060 = service not installed.
if [ -n "$WIN_USER" ]; then
    sc_query="$(sc.exe query ssh-agent </dev/null 2>/dev/null | tr -d '\r' || true)"
    sc_config="$(sc.exe qc ssh-agent </dev/null 2>/dev/null | tr -d '\r' || true)"
    agent_state="$(awk '$1 == "STATE" { print $3; exit }' <<< "$sc_query")"
    agent_start="$(awk '$1 == "START_TYPE" { print $3; exit }' <<< "$sc_config")"
    debug "Windows ssh-agent service state=${agent_state:-none} start_type=${agent_start:-none}"

    agent_advice() {
        hint "In PowerShell as administrator, run:"
        hint "  Stop-Service ssh-agent"
        hint "  Set-Service ssh-agent -StartupType Disabled"
        hint "Then quit CertAgent (right-click the tray icon) and start it again."
    }
    if [ "$agent_state" = "4" ]; then
        fail "The Windows OpenSSH Authentication Agent service is running"
        hint "It takes the place of CertAgent, so CertAgent's certificates are not used."
        agent_advice
    elif [ "$agent_start" = "2" ]; then
        warn "The Windows OpenSSH Authentication Agent service starts automatically"
        hint "It is stopped now, but at the next Windows start it takes the place of CertAgent."
        agent_advice
    else
        ok "Windows OpenSSH Authentication Agent service not active"
    fi
    unset -f agent_advice
fi

# Optional Windows SSH keys (--keys). Explicitly requested keys that are unusable are
# errors; keys kept from a previous run that disappeared are dropped with a warning.
WIN_SSH_DIR="$WIN_HOME/.ssh"
SSH_KEYS=()
if [ -n "$WIN_USER" ]; then
    case "$KEYS_MODE" in
        set)  read -r -a requested_keys <<< "${KEYS_ARG//,/ }" ;;
        none) requested_keys=() ;;
        keep) read -r -a requested_keys <<< "$(block_value "$BASHRC" '^SSH_keys_to_add=' 0 \
                  | sed -E 's/^SSH_keys_to_add=\((.*)\)[[:space:]]*$/\1/; s/["'\'']//g')" || true ;;
    esac
    if [ "$KEYS_MODE" = "set" ]; then problem=fail; else problem=warn; fi

    for key in "${requested_keys[@]}"; do
        first_line=""
        if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
            $problem "SSH key '$key' is not a plain file name"
            continue
        elif [ ! -f "$WIN_SSH_DIR/$key" ]; then
            $problem "SSH key '$key' not found in C:\\Users\\$WIN_USER\\.ssh"
            continue
        fi
        IFS= read -r first_line < "$WIN_SSH_DIR/$key" || true
        if [[ "$first_line" != "-----BEGIN "*"PRIVATE KEY-----"* ]]; then
            $problem "SSH key '$key' is not a private key file"
        else
            SSH_KEYS+=("$key")
        fi
    done

    if [ "${#SSH_KEYS[@]}" -gt 0 ]; then
        ok "Windows SSH keys to load at WSL start: ${SSH_KEYS[*]}"
    else
        # List the private keys that could be used with --keys
        available_keys=()
        for f in "$WIN_SSH_DIR"/*; do
            [ -f "$f" ] || continue
            first_line=""
            IFS= read -r first_line < "$f" || true
            if [[ "$first_line" == "-----BEGIN "*"PRIVATE KEY-----"* ]]; then
                available_keys+=("$(basename "$f")")
            fi
        done
        ok "No Windows SSH keys loaded at WSL start (optional)"
        if [ "${#available_keys[@]}" -gt 0 ]; then
            hint "To load some, rerun with e.g. --keys \"${available_keys[*]}\""
        fi
    fi
fi

# Windows ssh (PowerShell/CMD) gets the same hosts in C:\Users\<you>\.ssh\config
WIN_SSH_CONFIG_FILE="$WIN_SSH_DIR/config"
if [ -n "$WIN_USER" ]; then
    if [ -f /mnt/c/Windows/System32/OpenSSH/ssh.exe ]; then
        ok "Windows OpenSSH client"
    else
        warn "Windows OpenSSH client not found"
        hint "WSL works without it. To use ssh in PowerShell/CMD as well, add the optional"
        hint "feature 'OpenSSH Client' in Windows Settings -> System -> Optional features."
    fi
    # A config file made with 'echo ... > config' in Windows PowerShell 5 is UTF-16
    if [ -f "$WIN_SSH_CONFIG_FILE" ] && [ "$(tr -cd '\000' < "$WIN_SSH_CONFIG_FILE" | wc -c)" -gt 0 ]; then
        fail "C:\\Users\\$WIN_USER\\.ssh\\config is not a plain text (UTF-8) file"
        hint "Windows ssh cannot read it either. Save it as UTF-8 (e.g. in Notepad) and run again."
    fi
fi

# Existing config files must not contain a half-removed managed block
for f in "$SSH_CONFIG_FILE" "$BASHRC" ${WIN_USER:+"$WIN_SSH_CONFIG_FILE"}; do
    if ! markers_balanced "$f"; then
        fail "$(pretty "$f") has an incomplete '$BLOCK_START' block"
        hint "Remove the leftover '$BLOCK_START' / '$BLOCK_END' lines and run again."
    fi
done

# Own entries for the same hosts would override the ones this script adds
for f in "$SSH_CONFIG_FILE" ${WIN_USER:+"$WIN_SSH_CONFIG_FILE"}; do
    hosts="$(other_host_entries "$f")"
    if [ -n "$hosts" ]; then
        warn "$(pretty "$f") already has Host entries for: $hosts"
        hint "Settings there take precedence over the ones this script adds. Remove those"
        hint "entries unless you want to keep them."
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

### <<< 2. Create .ssh/config >>>
# Make sure ~/.ssh exists with correct permissions
debug "Checking $SSH_DIR"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
mkdir -p "$LOCAL_BIN"



### <<< 3. Add s and cluster config >>>
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
$BLOCK_END
EOF

write_managed_block "$SSH_CONFIG_FILE" "$WORK_DIR/ssh_block" 600
report "$RESULT" "$SSH_CONFIG_FILE"

# Same hosts for ssh in PowerShell/CMD. Windows ssh uses CertAgent directly (it serves
# the default agent pipe \\.\pipe\openssh-ssh-agent), so no kmkcheck proxy is needed.
# The nested ssh is called by full path, as Windows ssh runs ProxyCommand without a shell.
# No chmod: files on /mnt/c get the (user-only) permissions of C:\Users\<you>.
cat > "$WORK_DIR/win_ssh_block" <<EOF
$BLOCK_START
Host s s.fys.kuleuven.be
  HostName s.fys.kuleuven.be
  User $SSH_USER
  ForwardAgent yes
  ServerAliveInterval 240
Host cluster cluster-last cluster.fys.kuleuven.be cluster-last.fys.kuleuven.be
  ProxyCommand ssh %r@s /usr/bin/ballast-login %h
  User $SSH_USER
  ForwardAgent yes
  ForwardX11 yes
  ServerAliveInterval 240
  HostKeyAlias cluster.fys.kuleuven.be
$BLOCK_END
EOF

mkdir -p "$WIN_SSH_DIR"
write_managed_block "$WIN_SSH_CONFIG_FILE" "$WORK_DIR/win_ssh_block"
report "$RESULT" "$WIN_SSH_CONFIG_FILE"



### <<< 4. Add kmk  and helper script >>>
cat > "$WORK_DIR/kmkcheck" <<'EOF'
#!/usr/bin/env bash
trap 'trap - INT; kill -INT -- -$$' INT

ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then
  echo "Error: No SSH agent running." >&2
  exit 1
fi

valid_until="$(ssh-add -L | grep cert |grep vaultssh | head -n1 | ssh-keygen -L -f /dev/stdin | grep Valid |awk '{print $5}')"
if [ -z "$valid_until" ] || [ "$(date +%s)" -gt "$(date -d "$valid_until" +%s)" ]
then
  kmk
fi

exec /usr/bin/nc "$1" "$2"
EOF

install_file "$WORK_DIR/kmkcheck" "$KMKCHECK_FILE" 755
report "$RESULT" "$KMKCHECK_FILE"

# Install kmk as ~/.local/bin/kmk, whatever the download is called (only if missing;
# delete ~/.local/bin/kmk to reinstall from Downloads)
if [ "$KMK_SOURCE" = "$LOCAL_BIN/kmk" ]; then
    report unchanged "$LOCAL_BIN/kmk"
else
    install -m 0755 "$KMK_SOURCE" "$LOCAL_BIN/kmk"
    report created "$LOCAL_BIN/kmk"
fi

# kmk config: only (re)write when principals differ. 'kmk config write' always exits 0,
# even on errors, so check the file itself afterwards. --overwrite keeps the other
# settings from the existing file and only replaces principals.
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



### <<< 5. set up npiperelay >>>
if [ -f "$LOCAL_BIN/npiperelay.exe" ]; then
    report unchanged "$LOCAL_BIN/npiperelay.exe"
else
    debug "Downloading $NPIPERELAY_URL"
    if ! curl -fsSL -o "$WORK_DIR/npiperelay.zip" "$NPIPERELAY_URL"; then
        die "Failed to download npiperelay from $NPIPERELAY_URL"
    fi
    unzip -q -o "$WORK_DIR/npiperelay.zip" -d "$WORK_DIR/npiperelay"
    if [ ! -f "$WORK_DIR/npiperelay/npiperelay.exe" ]; then
        die "npiperelay.exe not found in downloaded zip"
    fi
    install -m 0755 "$WORK_DIR/npiperelay/npiperelay.exe" "$LOCAL_BIN/npiperelay.exe"
    report created "$LOCAL_BIN/npiperelay.exe"
fi



### <<< 6. set up .bashrc >>>
# Create $BASHRC if the file does not exist
if [ ! -f "$BASHRC" ]; then
    if [ -f /etc/skel/.bashrc ]; then
        debug "No $BASHRC found, copying from skel"
        install -m 0644 /etc/skel/.bashrc "$BASHRC"
    else
        debug "/etc/skel/.bashrc not found, starting with an empty $BASHRC"
    fi
fi

cat > "$WORK_DIR/bashrc_block" <<EOF
$BLOCK_START
# Make sure ~/.local/bin (kmk, kmkcheck, npiperelay) is on PATH
case ":\$PATH:" in
  *":$LOCAL_BIN:"*) ;;
  *) export PATH="$LOCAL_BIN:\$PATH" ;;
esac

# Connect WSL to the Windows agent (CertAgent): keys added on Windows are available here too
_hook_agent() {
  export SSH_AUTH_SOCK=\$HOME/.ssh/agent.sock
  # Checking if we're already running
  # need 'ps -ww' to get non-truncated command for matching
  # use square brackets to generate a regex match for the process we want but that doesn't match the grep command running it!
  ps -auxww | grep -q "[n]piperelay.exe -ei -s //./pipe/openssh-ssh-agent" >/dev/null 2>&1
  if [[ "\$?" != "0" ]]; then
      if [[ -S \$SSH_AUTH_SOCK ]]; then
          # not expecting the socket to exist as the forwarding command isn't running (http://www.tldp.org/LDP/abs/html/fto.html)
          echo "removing previous socket..."
          rm \$SSH_AUTH_SOCK
      fi
      echo "Starting SSH-Agent relay..."
      # setsid to force new session to keep running
      # set socat to listen on \$SSH_AUTH_SOCK and forward to npiperelay which then forwards to openssh-ssh-agent on windows
      (setsid socat UNIX-LISTEN:\$SSH_AUTH_SOCK,fork EXEC:"$LOCAL_BIN/npiperelay.exe -ei -s //./pipe/openssh-ssh-agent",nofork &) >/dev/null 2>&1
      # wait (max 2s) until socat listens, so the agent can be used right away
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do
          [[ -S \$SSH_AUTH_SOCK ]] && break
          sleep 0.2
      done
  fi
}

if [ ! -f "$LOCAL_BIN/npiperelay.exe" ]; then
  echo "Error! Download and unzip npiperelay from https://github.com/jstarks/npiperelay/releases."
  echo "And move it to ~/.local/bin/npiperelay.exe"
else
  _hook_agent
fi
unset -f _hook_agent
EOF

if [ "${#SSH_KEYS[@]}" -eq 0 ]; then
    cat >> "$WORK_DIR/bashrc_block" <<EOF

# Optional: load SSH keys from your Windows .ssh folder at WSL start.
# Not enabled; run setup_WSL.sh --keys "KEY ..." to enable.
$BLOCK_END
EOF
else
    cat >> "$WORK_DIR/bashrc_block" <<EOF

# Optional: load SSH keys from your Windows .ssh folder at WSL start, because
# CertAgent forgets keys after a restart. WSL cannot use the Windows key files
# directly (permissions), so they are cached in ~/.ssh/.windows-cached-keys.
# To change the list, run setup_WSL.sh --keys "KEY ..." (or --no-keys).
SSH_keys_to_add=($(printf '"%s" ' "${SSH_KEYS[@]}" | sed 's/ $//'))
SSH_key_location="$WIN_SSH_DIR"
SSH_key_cache="\$HOME/.ssh/.windows-cached-keys"
EOF
    cat >> "$WORK_DIR/bashrc_block" <<'EOF'
_load_windows_keys() {
  local key src cache fpfile fp
  mkdir -p "$SSH_key_cache" && chmod 700 "$SSH_key_cache"
  for key in "${SSH_keys_to_add[@]}"; do
    src="$SSH_key_location/$key"
    cache="$SSH_key_cache/$key"
    # Key deleted on Windows: drop the cached copy and skip it
    if [ ! -f "$src" ]; then
      rm -f -- "$cache" "$cache.pub"
      echo "Warning: Windows SSH key '$key' no longer exists, skipping it." >&2
      echo "         Remove it from SSH_keys_to_add in ~/.bashrc, or rerun setup_WSL.sh with --keys." >&2
      continue
    fi
    # New or changed on Windows: (re)cache it, after removing the old version from the agent
    if ! cmp -s -- "$src" "$cache"; then
      [ -f "$cache" ] && ssh-add -d "$cache" >/dev/null 2>&1
      cp -- "$src" "$cache" && chmod 600 "$cache"
    fi
    if [ -f "$src.pub" ]; then
      cmp -s -- "$src.pub" "$cache.pub" || cp -- "$src.pub" "$cache.pub"
    else
      rm -f -- "$cache.pub"
    fi
    # Load it unless the agent already has it
    fpfile="$cache"
    [ -f "$cache.pub" ] && fpfile="$cache.pub"
    fp="$(ssh-keygen -lf "$fpfile" 2>/dev/null | awk '{print $2}')"
    if [ -z "$fp" ] || ! ssh-add -l 2>/dev/null | grep -qF -- "$fp"; then
      echo "Loading Windows SSH key $key"
      ssh-add "$cache"
    fi
  done
}

if [ -S "${SSH_AUTH_SOCK:-}" ]; then
  _load_windows_keys
fi
unset -f _load_windows_keys
unset SSH_keys_to_add SSH_key_location SSH_key_cache
EOF
    printf '%s\n' "$BLOCK_END" >> "$WORK_DIR/bashrc_block"
fi

write_managed_block "$BASHRC" "$WORK_DIR/bashrc_block"
BASHRC_RESULT=$RESULT
report "$RESULT" "$BASHRC"



### <<< 7. Clean up cached Windows keys >>>
# Remove cached copies of keys that are no longer in the list
removed_keys=()
for f in "$KEY_CACHE_DIR"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    name="${name%.pub}"
    keep=0
    for key in "${SSH_KEYS[@]}"; do
        if [ "$key" = "$name" ]; then keep=1; fi
    done
    if [ "$keep" -eq 0 ]; then
        rm -f -- "$f"
        [[ " ${removed_keys[*]} " == *" $name "* ]] || removed_keys+=("$name")
    fi
done
if [ "${#removed_keys[@]}" -gt 0 ]; then
    ok "Removed cached keys no longer loaded: ${removed_keys[*]}"
    CHANGED=$((CHANGED + 1))
fi

# Older versions cached keys in ~/.ssh/.windows: remove copies identical to the Windows file
if [ -d "$OLD_KEY_CACHE_DIR" ]; then
    for f in "$OLD_KEY_CACHE_DIR"/*; do
        [ -f "$f" ] || continue
        if cmp -s -- "$f" "$WIN_SSH_DIR/$(basename "$f")"; then rm -f -- "$f"; fi
    done
    if rmdir -- "$OLD_KEY_CACHE_DIR" 2>/dev/null; then
        ok "Removed old key cache $(pretty "$OLD_KEY_CACHE_DIR")"
        CHANGED=$((CHANGED + 1))
    else
        warn "Old key cache $(pretty "$OLD_KEY_CACHE_DIR") still contains files"
        hint "These are copies of Windows keys made by an older version of this script."
        hint "Check and delete them: rm -r $(pretty "$OLD_KEY_CACHE_DIR")"
    fi
fi



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
    printf '\nPlease restart your laptop to activate these changes,\n'
    printf "or at least run %s from PowerShell and wait 10s.\n" "${C_BOLD}wsl --shutdown${C_RESET}"
fi
printf '\nThen open a new WSL terminal and connect with: %sssh s%s or %sssh cluster%s\n' \
    "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
printf 'The same commands work in PowerShell/CMD, once CertAgent holds a valid certificate.\n'
