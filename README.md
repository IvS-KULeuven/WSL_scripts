# WSL_scripts
Tools for WSL

## Setup
1. Clone this repo inside WSL
```shell
cd
git clone https://github.com/IvS-KULeuven/WSL_scripts.git
```
2. Add the scripts you want to your .bashrc
```shell
cat << 'EOF' >> ~/.bashrc
source ~/WSL_scripts/shared_ssh_agent.sh
source ~/WSL_scripts/kmkssh.sh
EOF
```
