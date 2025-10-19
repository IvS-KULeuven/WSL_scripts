# Couple of variables you need to tweak!!
Windows_username="Maarten" # case sensitive
npiperelay_path="/mnt/c/Users/$Windows_username/code/bin/npiperelay.exe"
SSH_keys_to_add=("id_rsa" "id_ecdsa") # Add a space separated list of keys you want to add from your Windows SSH agent; optional

hook_agent() {
  export SSH_AUTH_SOCK=$HOME/.ssh/agent.sock
  # Checking if we're already running
  # need `ps -ww` to get non-truncated command for matching
  # use square brackets to generate a regex match for the process we want but that doesn't match the grep command running it!
  ps -auxww | grep -q "[n]piperelay.exe -ei -s //./pipe/openssh-ssh-agent" 2>&1 > /dev/null
  if [[ "$?" != "0" ]]; then
      if [[ -S $SSH_AUTH_SOCK ]]; then
          # not expecting the socket to exist as the forwarding command isn't running (http://www.tldp.org/LDP/abs/html/fto.html)
          echo "removing previous socket..."
          rm $SSH_AUTH_SOCK
      fi
      echo "Starting SSH-Agent relay..."
      # setsid to force new session to keep running
      # set socat to listen on $SSH_AUTH_SOCK and forward to npiperelay which then forwards to openssh-ssh-agent on windows
      (setsid socat UNIX-LISTEN:$SSH_AUTH_SOCK,fork EXEC:"$npiperelay_path -ei -s //./pipe/openssh-ssh-agent",nofork &) >/dev/null 2>&1
  fi
}

if [ ! -f "$npiperelay_path" ]; then
  echo "Error! Download and unzip npiperelay from https://github.com/jstarks/npiperelay/releases.\nFinally, add the path to the npiperelay_path variable";
else
  hook_agent
fi

##
# Optional part!
##

# Now that we have an agent, we can load some keys
# We define which keys we want to import in an array
SSH_key_location="/mnt/c/Users/$Windows_username/.ssh"
for key in "${SSH_keys_to_add[@]}"; do
        # for each, we check if the key is already loaded
        keypath="$SSH_key_location/$key"
        ssh-add -l | grep -w "$(ssh-keygen -lf "${keypath}"|awk '{print $2}')" 2>&1 > /dev/null
        # if it isn't, we load the key
        # To circumvent permission issues,
        # we copy the key to .ssh/.windows
        if [[ "$?" != "0" ]]; then
                mkdir -p "$HOME/.ssh/.windows"
                cp "${keypath}" "$HOME/.ssh/.windows/$key"
                chmod 600 "$HOME/.ssh/.windows/$key"
                echo "Importing $key"
                ssh-add "$HOME/.ssh/.windows/$key"
                unset keypath
        fi
done

##
# clean up
##

# get rid of variabled that are no longer necessary
unset SSH_key_location
unset Windows_username
unset npiperelay_path
unset Agent_socket_path
unset SSH_keys_to_add
