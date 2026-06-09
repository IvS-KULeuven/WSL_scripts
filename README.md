# WSL_scripts
This is a setup script to connec the WSL ssh-agent to your Windows ssh-agent.

This script assumes:
- Your WSL is running Ubuntu
- You have KU Leuven's CertAgent installed and set to AutoStart (right-click the tray icon and make sure AutoStart is checked)
- You have downloaded the [kmk binary](https://admin.kuleuven.be/icts/services/ssh-cert/kmk) from ICTS and placed it in your Windows Downloads folder

## Functionality
- performs a software check for necessary software and advises otherwise
- asks for your r-number (or u- or b-number)
- creates ~/.ssh/config if needed
- adds host entries to ~/.ssh/config
- creates a helper command in ~/.local/bin
- adds ~/.local/bin to PATH in ~/.bashrc if needed
- downloads npiperelay to communicate with Windows CertAgent
- sets up the necessary config in ~/.bashrc to make it work
- Optionally: add windows SSH keys to agent on WSL startup. (Modify the `SSH_keys_to_add=()` line in your `.bashrc`)


## Setup
1. Clone this repo inside WSL
```shell
cd
git clone https://github.com/IvS-KULeuven/WSL_scripts.git
```
2. Run the setup.sh script
```shell
cd WSL_scripts
bash setup.sh
```
## Other files aside setup.sh
This repo also includes some other files. Those are the manual approach. `setup.sh` does not read these, they are included inside that script in a slightly different form for automation. If you don't trust running scripts from the internet or want to investigate yourself, feel free to inspect.
- `.bashrc`: entries for your `~/.bashrc`
- `kmkcheck`: placed under `~/.local/bin`
- `shared_ssh_agent.sh`: sourced in `.bashrc`
- `ssh_config`: entries for `~/.ssh/config`
