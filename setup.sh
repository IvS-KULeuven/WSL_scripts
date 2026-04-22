#!/usr/bin/env bash
set -euo pipefail

# Simple setup script for IvS ssh access on WSL Ubuntu
# This script:
# 0. performs a software check for necessary software and advises otherwise
# 1. asks for your r-number (or u- or b-number)
# 2. creates ~/.ssh if needed
# 3. adds host entries to ~/.ssh/config
# 4. creates a helper command in ~/.local/bin
# 5. adds ~/.local/bin to PATH in ~/.bashrc if needed
# 6. downloads npiperelay to communicate with Windows CertAgent
# 7. sets up the necessary config in ~/.bashrc to make it work

echo
echo "=== KU Leuven NS SSH setup for WSL Ubuntu ==="
echo

missing_packages=()

command -v nc >/dev/null 2>&1 || missing_packages+=("netcat-openbsd")
command -v socat >/dev/null 2>&1 || missing_packages+=("socat")
command -v curl >/dev/null 2>&1 || missing_packages+=("curl")
command -v unzip >/dev/null 2>&1 || missing_packages+=("unzip")
command -v ssh >/dev/null 2>&1 || missing_packages+=("openssh-client")

if [ "${#missing_packages[@]}" -gt 0 ]; then
    echo "This script needs some Ubuntu packages that are not installed yet."
    echo
    echo "Run this command, then start the script again:"
    printf 'sudo apt update && sudo apt install -y'
    printf ' %q' "${missing_packages[@]}"
    printf '\n'
    exit 1
fi

# Ask for SSH username
read -r -p "Enter your KU Leuven username (r-number, u-number) " SSH_USER

if [ -z "$SSH_USER" ]; then
    echo "No username entered. Stopping."
    exit 1
fi

## Optional: ask for key path
#DEFAULT_KEY="$HOME/.ssh/id_ed25519"
#read -r -p "Enter the SSH private key path [$DEFAULT_KEY]: " SSH_KEY
#SSH_KEY="${SSH_KEY:-$DEFAULT_KEY}"

# Make sure ~/.ssh exists with correct permissions
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

CONFIG_FILE="$HOME/.ssh/config"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo
echo "Adding .ssh/config entries for 's' and 'cluster'"
echo

BLOCK_START="# >>> KU Leuven NS WSL SSH setup >>>"
BLOCK_END="# <<< KU Leuven NS WSL SSH setup <<<"

TMP_FILE="$(mktemp)"

# Remove old managed block if present, then write fresh content
awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start {skip=1; next}
    $0 == end   {skip=0; next}
    !skip       {print}
' "$CONFIG_FILE" > "$TMP_FILE"

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

mv "$TMP_FILE" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "SSH config updated: $CONFIG_FILE"

# Create ~/.local/bin if needed
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

KMKCHECK_FILE="$LOCAL_BIN/kmkcheck"

cat > "$KMKCHECK_FILE" <<'EOF'
#!/usr/bin/env bash
trap 'trap - INT; kill -INT -- -$$' INT

echo "Right kmkcheck"
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

chmod +x "$HELPER_FILE"
echo "Helper command created: $HELPER_FILE"

# Check whether ~/.local/bin is already in PATH now
PATH_OK=0
case ":$PATH:" in
    *":$HOME/.local/bin:"*) PATH_OK=1 ;;
esac

BASHRC="$HOME/.bashrc"

if [ ! -f "$BASHRC" ]; then
    if [ -f /etc/skel/.bashrc ]; then
        install -m 0644 /etc/skel/.bashrc "$BASHRC"
    else
        echo "Warning: /etc/skel/.bashrc not found. Ignoring..." >&2
    fi
fi

# Check whether .bashrc already contains a generic ~/.local/bin setup
BASHRC_HAS_GENERIC=0
if grep -Eq '(\.local/bin|HOME/\.local/bin)' "$BASHRC" 2>/dev/null; then
    BASHRC_HAS_GENERIC=1
fi

if [ "$PATH_OK" -eq 1 ]; then
    echo "~/.local/bin is already in PATH."
elif [ "$BASHRC_HAS_GENERIC" -eq 1 ]; then
    echo "~/.bashrc already seems to handle ~/.local/bin."
else
    cat >> "$BASHRC" <<'EOF'

# Added by KU Leuven NS WSL SSH setup
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi
EOF
    echo "Added ~/.local/bin to PATH in $BASHRC"
fi

# Check if npiperelay is already present
if [ ! -f "$LOCAL_BIN/npiperelay.exe" ]; then
    tmpzip="$(mktemp /tmp/npiperelay.XXXXXX.zip)"
    tmpdir="$(mktemp -d /tmp/npiperelay.XXXXXX)" || exit 1
    if curl -Lf -o "$tmpzip" "https://github.com/jstarks/npiperelay/releases/download/v0.1.0/npiperelay_windows_amd64.zip"
    then
        unzip -o "$tmpzip" -d "$tmpdir"
        if [ -f "$tmpdir/npiperelay.exe" ]; then
            install -m 0755 "$tmpdir/npiperelay.exe" "$LOCAL_BIN/npiperelay.exe"
        else
            echo "npiperelay.exe not found in downloaded zip" >&2
            exit 1
        fi
        rm -f "$tmpzip"
        chmod +x "$LOCAL_BIN/npiperelay.exe"
    else
        echo "Failed to download npiperelay zip" >&2
        exit 1
    fi    
    case "$tmpdir" in
        /tmp/npiperelay.*)
            rm -r -- "$tmpdir"
            ;;
        *)
            echo "Warning: Refusing to delete unexpected temporary directory: $tmpdir. Ignoring..." >&2
            ;;
    esac
fi


# Remove old managed block if present in .bashrc, then write fresh content
TMP_BASHRC_FILE="$(mktemp)"
awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
    $0 == start {skip=1; next}
    $0 == end   {skip=0; next}
    !skip       {print}
' "$CONFIG_FILE" > "$TMP_BASHRC_FILE"

cat >> "$TMP_BASHRC_FILE" <<EOF

$BLOCK_START
# Add a space separated list of keys you want to add from your Windows SSH agent; optional
# For example:
# SSH_keys_to_add=("id_rsa" "id_ecdsa")
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
SSH_key_location="/mnt/c/Users/\$USERNAME/.ssh"
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

echo
echo "Setup finished."
echo
echo "You can now:"
echo "  1. Open a new shell, or run: source ~/.bashrc"
echo "  2. Connect with: ssh myserver"
echo "  3. Or use the helper: ssh-go myserver"
echo

