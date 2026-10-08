# IvS SSH setup scripts

Setup scripts to connect to the Department of Physics servers (`s` and `cluster`). There is one script per system:

| You work on | Script | Uses |
|---|---|---|
| Windows (WSL Ubuntu) | `setup_WSL.sh` | CertAgent on Windows, `kmk` in WSL |
| Linux | `setup_linux.sh` | `kmk` and an ssh-agent |
| macOS | `setup_macos.sh` | `kmk` and the macOS ssh-agent + Keychain |

After setup, `ssh s` and `ssh cluster` just work: when your certificate has expired, `kmk`
runs automatically to get a new one.


## Before you start

### Windows (WSL)
1. Install [CertAgent](https://admin.kuleuven.be/icts/services/ssh-cert/ssh-certificates-for-windows)
   and set it to start automatically (right-click the tray icon and check **AutoStart**).
2. Download the **Linux** version of kmk:
   [kmk-x86_64-latest](https://w.fys.kuleuven.be/public/deploy/Linux/kmk/kmk-x86_64-latest).
   Leave it in your Windows **Downloads** folder; the script finds and installs it.
3. Have WSL with Ubuntu installed. The script tells you if any Ubuntu packages are
   missing, and how to install them.

### Linux
1. Download kmk for Linux:
   [kmk-x86_64-latest](https://w.fys.kuleuven.be/public/deploy/Linux/kmk/kmk-x86_64-latest).
   Leave it in your **Downloads** folder.
2. Use bash as your shell (see [Notes](#notes) if you use another shell).

### macOS
1. Download kmk for your Mac and leave it in your **Downloads** folder:
   - Apple silicon (M1 and later): [kmk-arm64-latest](https://w.fys.kuleuven.be/public/deploy/Darwin/kmk/kmk-arm64-latest)
   - Intel: [kmk-x86_64-latest](https://w.fys.kuleuven.be/public/deploy/Darwin/kmk/kmk-x86_64-latest)

   Not sure? Apple menu → About This Mac: "Chip: Apple M…" means Apple silicon.
2. Optional: install [XQuartz](https://www.xquartz.org) if you want to run graphical
   programs on the cluster.

You don't need to rename the kmk download: the scripts install it as `~/.local/bin/kmk`.


## Install

Open a terminal (on Windows: your **WSL Ubuntu** terminal, not PowerShell) and run the
line for your system:

**Windows (WSL)**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvS-KULeuven/WSL_scripts/main/setup_WSL.sh)
```

**Linux**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvS-KULeuven/WSL_scripts/main/setup_linux.sh)
```

**macOS**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvS-KULeuven/WSL_scripts/main/setup_macos.sh)
```

The script first checks everything it needs and lists all problems at once. If something
is missing, it changes nothing: fix the items marked ✗ and run the same line again. When
all checks pass, it asks for your KU Leuven username (r-, u- or b-number) and sets
everything up.

> Use `bash <(curl ...)` exactly as shown, not `curl ... | bash`. The script asks for your
> username, and that does not work when the script itself is piped into bash.

Prefer to read the script before running it? Clone the repository instead:
```bash
git clone https://github.com/IvS-KULeuven/WSL_scripts.git
cd WSL_scripts
bash setup_WSL.sh      # or setup_linux.sh / setup_macos.sh
```


## Connect

```bash
ssh s          # the login server s.fys.kuleuven.be
ssh cluster    # the cluster, through s
```

The first time (and whenever your certificate has expired), kmk runs to get a new
certificate. Log in with your KU Leuven account and MFA when asked.

**Windows:** after the setup, restart your laptop, or run `wsl --shutdown` in PowerShell
and wait 10 seconds. Then open a new WSL terminal. `ssh s` and `ssh cluster` also work in
PowerShell and CMD. There, kmk does not run automatically: if the connection is refused,
Rigth-click CertAgent in the tray to `Renew certificate`.


## What the scripts change

All scripts put their settings between `# >>> KU Leuven NS ... SSH setup >>>` and
`# <<< ... <<<` marker lines. Running a script again replaces that block and never
duplicates it, so it is safe to rerun at any time (for example after fixing a typo 
in your username). Your own settings outside the block are left alone.

| | WSL | Linux | macOS |
|---|---|---|---|
| `~/.ssh/config`: hosts `s` and `cluster` | ✓ | ✓ | ✓ |
| `~/.local/bin/kmk`, `~/.local/bin/kmkcheck`, kmk config with your username | ✓ | ✓ | ✓ |
| Shell startup file: `~/.local/bin` on PATH | `~/.bashrc` | `~/.bashrc` | `~/.zshrc` or `~/.bash_profile` |
| ssh-agent | connects WSL to CertAgent (`npiperelay`, `socat`) | uses the desktop's agent, or starts one shared agent | uses the macOS agent and stores key passphrases in the Keychain |
| Windows `C:\Users\<you>\.ssh\config`: hosts `s` and `cluster` | ✓ | | |

`kmkcheck` is a small helper that ssh runs before connecting to `s`: it checks whether
the agent holds a valid certificate and runs kmk if not.


## Options

`setup_WSL.sh` can load SSH keys from your Windows `.ssh` folder into the agent every time
WSL starts (CertAgent forgets keys after a restart):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/IvS-KULeuven/WSL_scripts/main/setup_WSL.sh) --keys "id_ed25519 id_rsa"
```

Use `--no-keys` to stop loading them. Without either option, a rerun keeps your previous
choice. `--help` shows all options.

All scripts understand these environment variables:
- `LOG_LEVEL=3` shows debug output, e.g. `LOG_LEVEL=3 bash setup_linux.sh`
- `NO_COLOR=1` disables colored output


## Notes

- **Windows: the "OpenSSH Authentication Agent" service.** This Windows service uses the
  same connection as CertAgent, so it must be off. The script checks this and tells you how
  to stop and disable it (PowerShell as administrator:
  `Stop-Service ssh-agent; Set-Service ssh-agent -StartupType Disabled`, then restart
  CertAgent).
- **Linux with another shell than bash.** The script still runs, but you need to copy the
  marked block from `~/.bashrc` to your own shell's startup file.
- **New kmk version.** The scripts don't replace an installed kmk. To update it, run
  `kmk --update`.
- **Own entries for `s` or `cluster`.** If your ssh config already has its own `Host s`
  or `Host cluster` entries, those take precedence. The scripts warn about this; remove
  the old entries unless you want to keep them.


## Uninstall

1. Remove the marked `KU Leuven NS ... SSH setup` blocks from `~/.ssh/config` and your
   shell startup file (and on Windows also from `C:\Users\<you>\.ssh\config`).
2. Delete `~/.local/bin/kmk` and `~/.local/bin/kmkcheck` (WSL: also
   `~/.local/bin/npiperelay.exe` and `~/.ssh/.windows-cached-keys`).


## Manual setup

The folder `bits_and_pieces` contains the pieces of the WSL setup as separate files, for
those who prefer to set things up by hand. The scripts don't use these files: they
contain their own (slightly different) versions.

- `.bashrc`: entries for your `~/.bashrc`
- `shared_ssh_agent.sh`: connects WSL to CertAgent, sourced from `.bashrc`
- `kmkcheck`: goes in `~/.local/bin`
- `ssh_config`: entries for `~/.ssh/config`
