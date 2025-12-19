# KODEMACHINE
## Software-Defined Workstation v1.0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### DESIGN

```
SECURITY > STABILITY > PREDICTABILITY > UNIFORMITY
```

Goals:
  - Stateless, disposable compute
  - Identical env: local VM, cloud, bare metal
  - Encrypted portable drive
  - arm64 everywhere
  - CLI-first, GUI on-demand

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### ARCHITECTURE

```
┌─────────────────────────────────────────────────────┐
│  HOST: macOS                                        │
│  ~/.zshrc sources: dotfiles/kodemachine/host-cli.zsh│
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  UTM VM: kodemachine                          │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │  Ubuntu Server 24.04 LTS (arm64)        │  │  │
│  │  │  - CLI default                          │  │  │
│  │  │  - XFCE via startx                      │  │  │
│  │  │  - Podman rootless                      │  │  │
│  │  │  - asdf runtimes                        │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │                                               │  │
│  │  DRIVES:                                      │  │
│  │   vda: 50GB  OS        (disposable)          │  │
│  │   vdb: 50GB  Projects  (LUKS, portable)      │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### PREREQUISITES

On host mac:
  - UTM installed
  - Dotfiles cloned & sourced:
    ```bash
    git clone https://github.com/jikkujose/dotfiles.git ~/dotfiles
    # Add to ~/.zshrc:
    source ~/dotfiles/kodemachine/host-cli.zsh
    ```

Files in dotfiles:
  - `kodemachine/install-dependencies.zsh` (VM setup)
  - `kodemachine/host-cli.zsh` (host CLI wrapper)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## PHASE 1: PROVISION VM (UTM)

### 1.1 Create VM

Open UTM → Create New VM:

  - Type:       Virtualize > Linux
  - ISO:        ubuntu-24.04-live-server-arm64.iso
  - RAM:        16384 MB
  - CPU:        6 cores
  - GPU:        ✓ Enable Hardware OpenGL
  - OS Disk:    50 GB
  - Name:       kodemachine

### 1.2 Add Projects Drive

After creation:
  - Right-click VM → Edit → Drives
  - New Drive → VirtIO → 50 GB
  - Uncheck "Removable"

Drive order:
  1. ISO
  2. 50GB (OS)
  3. 50GB (Projects)

### 1.3 Install Ubuntu

Start VM, follow installer:
  - Name:      Kodeman
  - User:      kodeman
  - Hostname:  kodemachine
  - ✓ Install OpenSSH Server
  - Use entire 50GB for OS
  - IGNORE second 50GB drive

After install:
  - Shutdown
  - Remove ISO from drives

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## PHASE 2: ENCRYPTED STORAGE

Boot VM, login, run manually:

### 2.1 Identify Drive

```bash
lsblk
```

Expected:
```
vda   ← OS
vdb   ← Projects (empty)
```

### 2.2 Create LUKS Volume

```bash
# Format (type YES)
sudo cryptsetup luksFormat /dev/vdb

# Open
sudo cryptsetup open /dev/vdb crypt_projects

# Create filesystem
sudo mkfs.ext4 -L "Projects" /dev/mapper/crypt_projects
```

### 2.3 Mount

```bash
mkdir -p ~/Projects
sudo mount /dev/mapper/crypt_projects ~/Projects
sudo chown -R $USER:$USER ~/Projects
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## PHASE 3: SYSTEM SETUP

### 3.1 Clone Dotfiles

```bash
# Generate SSH key first
ssh-keygen -t ed25519 -C "kodeman@kodemachine" -N ""
cat ~/.ssh/id_ed25519.pub
```

Add key to GitHub, then:

```bash
git clone git@github.com:jikkujose/dotfiles.git ~/dotfiles
```

### 3.2 Run Installer

```bash
zsh ~/dotfiles/kodemachine/install-dependencies.zsh
```

This installs:
  - Core: zsh, neovim, tmux, git, podman
  - CLI: bat, fd, rg, jq, httpie, btop
  - GUI: xfce4, firefox, chromium, WhiteSur theme
  - Fonts: CaskaydiaCove Nerd Font
  - Runtimes: python, node, ruby, go, rust, bun
  - Tools: playwright

### 3.3 Link Podman Storage

```bash
mkdir -p ~/Projects/podman-storage
rm -rf ~/.local/share/containers
ln -s ~/Projects/podman-storage ~/.local/share/containers
```

### 3.4 Reboot

```bash
sudo reboot
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## PHASE 4: HOST SETUP

### 4.1 Get VM IP

In VM:
```bash
ip -4 addr show enp0s1 | grep inet
```

### 4.2 Configure Host CLI

Edit `~/dotfiles/kodemachine/host-cli.zsh`:

```bash
local ip="192.168.64.X"  # ← set actual IP
```

### 4.3 Source in Shell

Add to `~/.zshrc` on host mac:

```bash
source ~/dotfiles/kodemachine/host-cli.zsh
```

Reload:
```bash
exec zsh
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## DAILY OPERATIONS

### Workflow

```bash
# Start (headless) + SSH
kodemachine start

# Start with GUI window
kodemachine start --gui

# Inside VM: unlock drive (required after stop, not pause)
sudo cryptsetup open /dev/vdb crypt_projects
sudo mount /dev/mapper/crypt_projects ~/Projects

# Inside VM: launch GUI on-demand
startx

# End of day: pause (instant resume, state preserved)
kodemachine pause

# Full shutdown (requires LUKS unlock on next boot)
kodemachine stop
```

### Quick Reference

```
┌─────────────────────────────────────────────────────────────┐
│  HOST COMMANDS                                              │
├─────────────────────────────────────────────────────────────┤
│  kodemachine start        Headless + SSH                    │
│  kodemachine start --gui  GUI window + SSH                  │
│  kodemachine pause        Suspend (instant resume)          │
│  kodemachine stop         Shutdown                          │
│  kodemachine ssh          SSH only (if running)             │
│  kodemachine ip           Show IP                           │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  INSIDE VM                                                  │
├─────────────────────────────────────────────────────────────┤
│  startx                   Launch XFCE GUI                   │
│  sudo poweroff            Shutdown                          │
│  sudo reboot              Reboot                            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  UNLOCK (after stop/reboot only)                            │
├─────────────────────────────────────────────────────────────┤
│  sudo cryptsetup open /dev/vdb crypt_projects               │
│  sudo mount /dev/mapper/crypt_projects ~/Projects           │
└─────────────────────────────────────────────────────────────┘
```

### State Transitions

```
         start              start
STOPPED ──────→ RUNNING ←──────── PAUSED
    ↑              │                 ↑
    │     stop     │     pause       │
    └──────────────┴─────────────────┘
```

- **Pause→Start:** Instant, state preserved, no LUKS unlock
- **Stop→Start:** Full boot, requires LUKS unlock
- **Pause:** Uses ~16GB disk for RAM state

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## PORTABILITY

### Export Projects Drive

1. `kodemachine stop`
2. UTM → Right-click VM → Show in Finder
3. Copy the 50GB Projects QCOW2 file

The QCOW2 is:
  - LUKS encrypted at rest
  - Mountable on any QEMU/UTM host
  - Sparse (actual size = used space)

### Deploy to Cloud

```bash
# On fresh Ubuntu 24.04 arm64:
git clone git@github.com:jikkujose/dotfiles.git ~/dotfiles
zsh ~/dotfiles/kodemachine/install-dependencies.zsh --headless
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## FILES

```
dotfiles/
└── kodemachine/
    ├── install-dependencies.zsh   VM setup script
    └── host-cli.zsh               Host CLI wrapper
```

**install-dependencies.zsh**
  - Non-interactive, idempotent
  - `--headless` flag skips GUI
  - Installs everything except podman storage link

**host-cli.zsh**
  - Provides `kodemachine` command
  - Controls VM via utmctl
  - Auto-SSH on start

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## VERIFICATION

After setup, verify:

```bash
# Encrypted mount
df -h ~/Projects

# Podman storage
podman info | grep graphRoot
# → ~/Projects/podman-storage

# Runtimes
python --version && node --version && go version

# CLI tools
bat --version && fd --version && rg --version
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━