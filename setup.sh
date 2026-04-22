#!/usr/bin/env bash
set -euo pipefail

# Simple setup script for IvS ssh access on WSL Ubuntu
# This script:
# 0. performs a software check for necessary software and advises otherwise
# 1. asks for your r-number (or u- or b-number)
# 2. creates ~/.ssh/config if needed
# 3. adds host entries to ~/.ssh/config
# 4. creates a helper command in ~/.local/bin
# 5. adds ~/.local/bin to PATH in ~/.bashrc if needed
# 6. downloads npiperelay to communicate with Windows CertAgent
# 7. sets up the necessary config in ~/.bashrc to make it work


### Variables:
LOCAL_BIN="$HOME/.local/bin"
BASHRC="$HOME/.bashrc"
SSH_CONFIG_FILE="$HOME/.ssh/config"
KMKCHECK_FILE="$LOCAL_BIN/kmkcheck"
USERNAME="$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')"

### Loggin functions
LOG_LEVEL=${LOG_LEVEL:-2}
# 0 = ERROR
# 1 = WARNING
# 2 = INFO
# 3 = DEBUG

log() {
    local level_name=$1
    local level_num=$2
    shift 2

    (( LOG_LEVEL < level_num )) && return 0

    printf '[%s] %s\n' "$level_name" "$*" >&2
}

error() { log ERROR   0 "$@"; }
warn()  { log WARNING 1 "$@"; }
info()  { log INFO    2 "$@"; }
debug() { log DEBUG   3 "$@"; }

info "=== KU Leuven NS SSH setup for WSL Ubuntu ==="



### <<< 0. Software check >>>
missing_packages=()

command -v nc >/dev/null 2>&1 || missing_packages+=("netcat-openbsd")
command -v awk >/dev/null 2>&1 || missing_packages+=("gawk")
command -v socat >/dev/null 2>&1 || missing_packages+=("socat")
command -v curl >/dev/null 2>&1 || missing_packages+=("curl")
command -v unzip >/dev/null 2>&1 || missing_packages+=("unzip")
command -v ssh >/dev/null 2>&1 || missing_packages+=("openssh-client")

if [ "${#missing_packages[@]}" -gt 0 ]; then
    error "This script needs some Ubuntu packages that are not installed yet."
    error "Run this command, then start the script again:"
    printf 'sudo apt update && sudo apt install -y'
    printf ' %q' "${missing_packages[@]}"
    printf '\n'
    exit 1
fi

if [ ! -f "$LOCAL_BIN/kmk" ]
then
    if [ ! -f /mnt/c/Users/$USERNAME/Downloads/kmk ]
    then
        error "This script needs the KU Leuven kmk binary.
Please download it from here: https://admin.kuleuven.be/icts/services/ssh-cert/kmk
and save it in your Windows Downloads folder (C:\Users\$USERNAME\Downloads)"
        exit 1
    fi
fi


### <<< 1. Ask u-number >>>
# Ask for SSH username
read -r -p "Enter your KU Leuven username (r-number, u-number) " SSH_USER

if [ -z "$SSH_USER" ]; then
    error "No username entered. Stopping."
    exit 1
fi



### <<< 2. Create .ssh/config >>>
# Make sure ~/.ssh exists with correct permissions
debug "Checking $HOME/.ssh"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

debug "Checking $SSH_CONFIG_FILE"
touch "$SSH_CONFIG_FILE"
chmod 600 "$SSH_CONFIG_FILE"



### <<< 3. Add s and cluster config >>>
debug "Adding $SSH_CONFIG_FILE entries for 's' and 'cluster'"

BLOCK_START="# >>> KU Leuven NS WSL SSH setup >>>"
BLOCK_END="# <<< KU Leuven NS WSL SSH setup <<<"

TMP_FILE="$(mktemp)"
debug "TMP_FILE = $TMP_FILE"

# Remove old managed block if present, then write fresh content
awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start {skip=1; next}
    $0 == end   {skip=0; next}
    !skip       {print}
' "$SSH_CONFIG_FILE" > "$TMP_FILE"

cat >> "$TMP_FILE" <<EOF

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

mv "$TMP_FILE" "$SSH_CONFIG_FILE"
chmod 600 "$SSH_CONFIG_FILE"

info "Updated ssh config: $SSH_CONFIG_FILE"



### <<< 4. Add kmk helper scritp >>>
# Create ~/.local/bin if needed
debug "Checking $LOCAL_BIN"
mkdir -p "$LOCAL_BIN"

cat > "$KMKCHECK_FILE" <<'EOF'
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

chmod 755 "$KMKCHECK_FILE"

info "Updated $KMKCHECK_FILE"



### <<< 5. Add $LOCAL_BIN to path >>>
# Check whether $LOCAL_BIN is already in PATH now
# Create $BASHRC if the file does not exist
if [ ! -f "$BASHRC" ]; then
    if [ -f /etc/skel/.bashrc ]; then
	info "No $BASHRC found, copying from skel"
        install -m 0644 /etc/skel/.bashrc "$BASHRC"
    else
        warning "/etc/skel/.bashrc not found. Ignoring..." >&2
    fi
fi

debug "Check $LOCAL_BIN presence in PATH"
PATH_OK=0
case ":$PATH:" in
    *":$HOME/.local/bin:"*) PATH_OK=1 ;;
esac
# Check whether .bashrc already contains a generic ~/.local/bin setup
debug "Checking $BASHRC" 
BASHRC_HAS_GENERIC=0
if grep -Eq '(\.local/bin|HOME/\.local/bin)' "$BASHRC" 2>/dev/null; then
    BASHRC_HAS_GENERIC=1
fi

if [ "$PATH_OK" -eq 1 ]; then
    debug "$LOCAL_BIN is already in PATH."
elif [ "$BASHRC_HAS_GENERIC" -eq 1 ]; then
    debug "$BASHRC already seems to handle $LOCAL_BIN."
else
    cat >> "$BASHRC" <<EOF

# Added by KU Leuven NS WSL SSH setup
if [ -d "$LOCAL_BIN" ]; then
    export PATH="$LOCAL_BIN:\$PATH"
fi
EOF
    info "Added $LOCAL_BIN to PATH in $BASHRC"
fi



### <<< 6. set up npiperelay >>>
# Check if npiperelay is already present
if [ ! -f "$LOCAL_BIN/npiperelay.exe" ]; then
    tmpzip="$(mktemp /tmp/npiperelay.XXXXXX.zip)"
    tmpdir="$(mktemp -d /tmp/npiperelay.XXXXXX)" || exit 1
    debug "tmpzip = $tmpzip"
    debug "tmpdir = $tmpdir"
    if curl -Lf -o "$tmpzip" "https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip"
    then
        unzip -o "$tmpzip" -d "$tmpdir"
        if [ -f "$tmpdir/npiperelay.exe" ]; then
            install -m 0755 "$tmpdir/npiperelay.exe" "$LOCAL_BIN/npiperelay.exe"
        else
            error "npiperelay.exe not found in downloaded zip"
            exit 1
        fi
        rm -f "$tmpzip"
        chmod +x "$LOCAL_BIN/npiperelay.exe"
    else
        error "Failed to download npiperelay zip" >&2
        exit 1
    fi    
    case "$tmpdir" in
        /tmp/npiperelay.*)
            rm -r -- "$tmpdir"
            ;;
        *)
            warning "Refusing to delete unexpected temporary directory: $tmpdir. Ignoring..." >&2
            ;;
    esac
    info "Installed npiperelay to $LOCAL_BIN/npiperelay.exe"
else
    debug "npiperelay already present"
fi



### <<< 7. sets up npiperelay >>>
# Remove old managed block if present in .bashrc, then write fresh content
TMP_BASHRC_FILE="$(mktemp)"
debug "TMP_BASHRC_FILE = $TMP_BASHRC_FILE"
awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start {skip=1; next}
    $0 == end   {skip=0; next}
    !skip       {print}
' "$BASHRC" > "$TMP_BASHRC_FILE"

# Update block
cat >> "$TMP_BASHRC_FILE" <<EOF

$BLOCK_START
# Add a space separated list of keys you want to add from your Windows SSH agent; optional
# For example:
# SSH_keys_to_add=("id_rsa" "id_ed25519")
SSH_keys_to_add=()
_hook_agent() {
  export SSH_AUTH_SOCK=\$HOME/.ssh/agent.sock
  # Checking if we're already running
  # need `ps -ww` to get non-truncated command for matching
  # use square brackets to generate a regex match for the process we want but that doesn't match the grep command running it!
  ps -auxww | grep -q "[n]piperelay.exe -ei -s //./pipe/openssh-ssh-agent" 2>&1 > /dev/null
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
  fi
}

if [ ! -f "$LOCAL_BIN/npiperelay.exe" ]; then
  echo "Error! Download and unzip npiperelay from https://github.com/jstarks/npiperelay/releases.\nAnd move it to ~/.local/bin/npiperelay.exe";
else
  _hook_agent
fi

##
# Optional part!
##

# Now that we have an agent, we can load some keys
# We define which keys we want to import in an array
SSH_key_location="/mnt/c/Users/$USERNAME/.ssh"
for key in "\${SSH_keys_to_add[@]}"; do
        # for each, we check if the key is already loaded
        keypath="\$SSH_key_location/\$key"
        ssh-add -l | grep -w "\$(ssh-keygen -lf "\${keypath}"|awk '{print \$2}')" 2>&1 > /dev/null
        # if it isn't, we load the key
        # To circumvent permission issues,
        # we copy the key to .ssh/.windows
        if [[ "\$?" != "0" ]]; then
                mkdir -p "\$HOME/.ssh/.windows"
                cp "\${keypath}" "\$HOME/.ssh/.windows/\$key"
                chmod 600 "\$HOME/.ssh/.windows/\$key"
                echo "Importing \$key"
                ssh-add "\$HOME/.ssh/.windows/\$key"
                unset keypath
        fi
done


##
# clean up
##

# get rid of variabled that are no longer necessary
unset SSH_key_location
unset SSH_keys_to_add
unset -f _hook_agent
$BLOCK_END
EOF

mv "$TMP_BASHRC_FILE" "$BASHRC"
chmod 644
info "Updated $BASHRC"

info "Up to date!"
echo
echo "This script requires KU Leuven's CertAgent"
if tasklist.exe | grep -qi '^CertAgent.exe'
then
    info "CertAgent.exe is already running on Windows.
Make sure it is set to autostart (right click the icon in the Windows Tray -> autostart)"
else
    warning "CertAgent.exe is currently not running on Windows.
Make sure it is installed and set it to autostart (right click the icon in the Windows Tray -> autostart).
You can find the installer at https://admin.kuleuven.be/icts/services/ssh-cert/ssh-certificates-for-windows"
fi