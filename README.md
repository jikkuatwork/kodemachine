# Kodemachine

Ephemeral VM manager for macOS and Linux.

```bash
kodemachine create myproject  # Create clone, boot, SSH in
kodemachine suspend myproject # Instant pause
kodemachine start myproject   # Instant resume/reconnect
kodemachine delete myproject  # Gone
```

## Why

- Development environments accumulate cruft
- Docker helps but isn't always enough
- Full VMs are clean but slow to provision

Kodemachine gives you **disposable Linux VMs that boot in seconds**:

- **Instant clones** - APFS (macOS) or qcow2 backing files (Linux), zero disk overhead
- **Headless** - VMs run as background processes
- **SSH-native** - `start` drops you into a shell
- **Persistent storage** - Optional encrypted LUKS disk
- **Multi-platform** - Same CLI on macOS (UTM) and Linux (libvirt/KVM)

## Why Now: Isolating AI Agents

AI coding assistants (Claude Code, Aider, Copilot) are powerful but risky. They
execute code, install packages, and access your filesystem. In November 2025,
Anthropic documented the [first large-scale AI-orchestrated cyberattack][1] -
threat actors used Claude Code to compromise thirty organizations with minimal
human involvement.

The attack exploited three AI capabilities: **intelligence** (complex
instructions), **agency** (autonomous operation), and **tools** (filesystem and
network access). Attackers accomplished 80-90% of the campaign through AI
automation.

Meanwhile, researchers like [Dr. Anish Mohammed][@anish] ([talk][2]) warn about broader risks:
LLMs with access to lab equipment, sequencers, or critical infrastructure. The
same autonomy that makes AI assistants useful makes them dangerous when
compromised or misused.

**Kodemachine provides the first layer of defense:** disposable VMs where AI
tools run isolated from your host. Combined with container sandboxing (see
[testman][3]), you get defense in depth - AI agents can only access the project
directory, not your SSH keys, credentials, or other projects.

[1]: https://www.anthropic.com/news/disrupting-AI-espionage
[2]: https://www.youtube.com/watch?v=3bMsWeWR7hI
[3]: https://github.com/jikkuatwork/testman
[@anish]: https://x.com/anishmohammed

## Quick Start

### macOS

```bash
# 1. Setup host (once per Mac)
./setup-host.rb

# 2. Create base image (every ~6 months)
./create-base.rb

# 3. Daily workflow
kodemachine create myproject
kodemachine start myproject   # Later reconnects
```

### Linux

```bash
# 1. Setup host (once — checks libvirt/KVM, creates storage pool)
./setup-host.rb

# 2. Create a base Ubuntu VM in virt-manager (or virt-install)
#    Name it "ubuntu-base", use the host-native architecture,
#    create user "kodeman", and enable OpenSSH during install.
#    On x86_64 Linux, use the amd64 ISO/image (not ARM64 emulation).

# 3. Provision the base image
#    For AI-agent/container workloads, headless is usually enough:
./create-base.rb --skip-gui --skip-browsers

# 4. Daily workflow
kodemachine create myproject
kodemachine start myproject   # Later reconnects
```

## Architecture

Kodemachine uses the host's native CPU architecture for VMs: ARM64 on Apple
Silicon Macs, x86_64/amd64 on x86_64 Linux hosts. This keeps virtualization
near-native. Running ARM64 guests on an x86_64 Linux host requires CPU emulation
and is usually far too slow for compilers, browsers, package managers, and AI
agent tooling.

```
┌───────────────────────────────────────────────────────────┐
│ Host (macOS or Linux)                                     │
│                                                           │
│   setup-host.rb      One-time: Install dependencies       │
│         │            macOS: UTM + Homebrew                │
│         │            Linux: libvirt + KVM + storage pool  │
│         ▼                                                 │
│   create-base.rb     Every ~6 months: Build golden image  │
│         │            - Ubuntu + GUI + browsers            │
│         │            - SSH key baked in                   │
│         ▼                                                 │
│   kodemachine.rb     Daily: Create, start, stop, delete   │
│         │            macOS: UTM backend (APFS clones)    │
│         │            Linux: libvirt backend (qcow2 CoW)  │
│         ▼                                                 │
│   ┌───────────────────────────────────────────────────┐   │
│   │ km-myproject (instant clone)                      │   │
│   │   └── Your code, containers, etc.                 │   │
│   └───────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose | When to Run |
|------|---------|-------------|
| `setup-host.rb` | Install dependencies (UTM or libvirt) | Once per machine |
| `create-base.rb` | Build golden VM image | Every ~6 months |
| `kodemachine.rb` | VM lifecycle (create/start/stop/delete) | Daily |

## Setup Host

Run once on a new machine:

```bash
./setup-host.rb
```

### macOS
- Check/install Homebrew
- Install UTM (VM hypervisor)
- Install qemu-img (disk tools)
- Create config directory
- Setup `kodemachine` command symlink

### Linux
- Check KVM, libvirt, virsh, qemu-img
- Ensure user is in `libvirt` group
- Activate default NAT network
- Create `kodemachine` libvirt storage pool (`~/.local/share/kodemachine/images/`)
- Create sparse shared disk (`Shared/projects-luks.qcow2`, 64GB by default on Linux)
- Apply ACLs so the libvirt QEMU user can access the user-owned storage pool
- Create config directory
- Setup `kodemachine` command symlink

## Create Base Image

Run every ~6 months (or when you want a fresh golden image):

```bash
# Standard: provisions Ubuntu VM with your SSH key auto-detected
./create-base.rb

# With dotfiles
./create-base.rb --dotfiles git@github.com:you/dotfiles.git

# Skip GUI for headless-only use
./create-base.rb --skip-gui --skip-browsers
```

### Options

```
-n, --name NAME          Base image name (default: kodeimage-vYYYY.MM)
-u, --user USER          SSH username (default: kodeman)
-k, --host-ssh-key PATH  Host's public key (default: ~/.ssh/id_ed25519.pub)
-d, --dotfiles REPO      Git repo URL for dotfiles
    --ip ADDRESS         Manual IP if auto-detection fails
    --skip-gui           Skip XFCE installation
    --skip-browsers      Skip Firefox/Chromium
-v, --verbose            Show SSH commands
```

### What It Installs

| Category | Packages |
|----------|----------|
| Core | qemu-guest-agent, openssh, curl, wget, git, build-essential |
| GUI | XFCE4, xfce4-goodies, xfce4-terminal |
| Browsers | Firefox, Chromium |
| Fonts | Noto, Liberation, CaskaydiaCove Nerd Font |
| Tools | htop, btop, tree, jq, xclip |
| Containers | Podman, uidmap, fuse-overlayfs, slirp4netns |
| Shell | zsh (set as default) |

## Daily Commands

```
create <label>     Create VM from base image and SSH in
start <label>      Start/resume existing VM and SSH in
start base         Start base image directly (for modifications)
stop <label>       Graceful shutdown
suspend <label>    Pause to memory (instant resume)
delete <label>     Remove VM
status             System overview
status <label>     VM details with live metrics
list               List all VMs
attach <label>     Serial console (rescue/debug)
doctor             Check system health
```

### Flags

```
--gui              Show VM window (limit: one GUI VM)
--no-disk          Skip shared disk attachment
```

## Usage Examples

```bash
# Daily workflow
kodemachine create work
# ... code ...
kodemachine suspend work   # Instant pause
kodemachine start work     # Instant resume

# Multiple projects (concurrent)
kodemachine create api
kodemachine create frontend
kodemachine list

# Modify base image
kodemachine stop work         # Stop clones first
kodemachine start base
# ... install stuff ...
kodemachine stop base
# Future clones include changes

# Debug
kodemachine attach api        # Serial console
kodemachine status api        # Resource details
```

## Configuration

Location: `~/.config/kodemachine/config.json`

```json
{
  "base_image": "kodeimage-v2025.01",
  "ssh_user": "kodeman",
  "prefix": "km-",
  "headless": true,
  "shared_disk": "Shared/projects-luks.qcow2",
  "images_dir": "~/.local/share/kodemachine/images"
}
```

| Key | Description |
|-----|-------------|
| `base_image` | Golden image name in UTM/libvirt |
| `ssh_user` | SSH username |
| `prefix` | Clone name prefix |
| `headless` | Hide VM window |
| `shared_disk` | Shared disk path (relative to UTM docs on macOS, or `images_dir` on Linux) |
| `images_dir` | Linux-only VM image directory (default: `~/.local/share/kodemachine/images`) |

## Shared LUKS Disk

Encrypted disk that persists across ephemeral VMs.

See [LUKS_DRIVE_SETUP.md](LUKS_DRIVE_SETUP.md) for full setup.

Quick version:

```bash
# Inside VM
sudo cryptsetup luksFormat /dev/vdb
sudo cryptsetup luksOpen /dev/vdb projects
sudo mkfs.ext4 /dev/mapper/projects
sudo mkdir -p /mnt/projects
sudo mount /dev/mapper/projects /mnt/projects
```

## Dotfiles Integration

Any dotfiles repository works with kodemachine:

```bash
./create-base.rb --dotfiles git@github.com:you/dotfiles.git
```

The repo is cloned to `~/dotfiles`. If a `bootstrap.sh` script exists, it runs automatically. Otherwise, the repo is simply cloned for manual setup.

Example: [jikkujose/dotfiles](https://github.com/jikkujose/dotfiles) - cross-platform config for zsh, fish, neovim, and tmux.

## Shell Completion

### Bash / Zsh

Add to `~/.bashrc` or `~/.zshrc`:

```bash
# Zsh only:
autoload -Uz bashcompinit && bashcompinit

_kodemachine() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local cmd=${COMP_WORDS[1]}

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W \
      "create start resume stop suspend delete status list attach doctor" \
      -- "$cur"))
  elif [[ "$cmd" =~ ^(create|start|stop|suspend|delete|status|attach)$ ]]; then
    local labels=$(utmctl list 2>/dev/null \
      | grep 'km-' | awk '{print $3}' | sed 's/^km-//')
    COMPREPLY=($(compgen -W "base $labels" -- "$cur"))
  fi
}
complete -F _kodemachine kodemachine
```

### Fish

Save to `~/.config/fish/completions/kodemachine.fish`:

```fish
complete -c kodemachine -f
complete -c kodemachine -n "__fish_use_subcommand" \
  -a "create start resume stop suspend delete status list attach doctor"
complete -c kodemachine -n "__fish_seen_subcommand_from create start stop suspend delete status attach" \
  -a "base (utmctl list 2>/dev/null | grep 'km-' | awk '{print \$3}' | sed 's/^km-//')"
```

## Troubleshooting

**SSH fails after start**
```bash
kodemachine attach <label>
# Check: systemctl status qemu-guest-agent
```

**IP not detected**
- Use `--ip` flag with create-base.rb
- Check: `utmctl ip-address <vm-name>`

**"Device busy" errors**
- Force quit UTM, retry

**OSStatus -1712 / -10004**
- Apple Events timeout during I/O
- Usually transient, script retries

## Design Notes

- **No gem dependencies**: All scripts use Ruby standard library only (`json`, `fileutils`, `open3`, `optparse`, `rexml`, `securerandom`). Works with system Ruby on macOS and Linux.
- **Backend abstraction**: Platform-specific logic (UTM vs libvirt) is encapsulated in backend classes. Same CLI, same config format, same workflow.
- **No Brewfile**: Dependencies installed imperatively by setup-host.rb (Homebrew on macOS, apt on Linux).
- **Stateless scripts**: No daemon, no database. Config is a single JSON file.

## Related

- [testman](https://github.com/jikkuatwork/testman) - Container sandboxing layer
- [Blog: Disposable Dev Environments](https://jikkujose.in/2025/12/27/disposable-dev-environments.html) - Architecture overview

## License

MIT
