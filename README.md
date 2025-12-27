# Kodemachine

Ephemeral VM manager for macOS.

```bash
kodemachine start myproject   # Create clone, boot, SSH in
kodemachine suspend myproject # Instant pause
kodemachine start myproject   # Instant resume
kodemachine delete myproject  # Gone
```

## Why

- Development environments accumulate cruft
- Docker helps but isn't always enough
- Full VMs are clean but slow to provision

Kodemachine gives you **disposable Linux VMs that boot in seconds**:

- **Instant clones** - APFS copy-on-write, zero disk overhead
- **Headless** - VMs run as background processes
- **SSH-native** - `start` drops you into a shell
- **Persistent storage** - Optional encrypted LUKS disk

## Quick Start

```bash
# 1. Setup host (once per Mac)
./setup-host.rb

# 2. Create base image (every ~6 months)
./create-base.rb --dotfiles git@github.com:you/dotfiles.git --ssh-key ~/.ssh/id_ed25519.pub

# 3. Daily workflow
kodemachine start myproject
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ macOS Host                                                  │
│                                                             │
│   setup-host.rb      One-time: Install UTM, dependencies   │
│         │                                                   │
│         ▼                                                   │
│   create-base.rb     Every ~6 months: Build golden image   │
│         │            - Ubuntu + GUI + browsers              │
│         │            - Your dotfiles (via bootstrap.sh)     │
│         │            - SSH key baked in                     │
│         ▼                                                   │
│   kodemachine.rb     Daily: Clone, start, stop, delete     │
│         │                                                   │
│         ▼                                                   │
│   ┌─────────────────────────────────────────────────────┐  │
│   │ km-myproject (APFS clone)                           │  │
│   │   └── Your code, testman containers, etc.           │  │
│   └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose | When to Run |
|------|---------|-------------|
| `setup-host.rb` | Install UTM, qemu-img, create symlinks | Once per Mac |
| `create-base.rb` | Build golden VM image | Every ~6 months |
| `kodemachine.rb` | VM lifecycle (start/stop/clone) | Daily |

## Setup Host

Run once on a new Mac:

```bash
./setup-host.rb
```

This will:
- Check/install Homebrew
- Install UTM (VM hypervisor)
- Install qemu-img (disk tools)
- Create config directory
- Setup `kodemachine` command symlink

## Create Base Image

Run every ~6 months (or when you want a fresh golden image):

```bash
# Minimal: just provision an existing Ubuntu VM
./create-base.rb

# Full: with dotfiles and SSH key
./create-base.rb \
  --dotfiles git@github.com:you/dotfiles.git \
  --ssh-key ~/.ssh/id_ed25519.pub

# Skip GUI for headless-only use
./create-base.rb --skip-gui --skip-browsers
```

### Options

```
-n, --name NAME        Base image name (default: kodeimage-vYYYY.MM)
-u, --user USER        SSH username (default: kodeman)
-k, --ssh-key PATH     SSH public key to inject
-d, --dotfiles REPO    Git repo URL for dotfiles
    --ip ADDRESS       Manual IP if auto-detection fails
    --skip-gui         Skip XFCE installation
    --skip-browsers    Skip Firefox/Chromium
-v, --verbose          Show SSH commands
```

### What It Installs

| Category | Packages |
|----------|----------|
| Core | qemu-guest-agent, openssh, curl, wget, git, build-essential |
| GUI | XFCE4, xfce4-goodies, xfce4-terminal |
| Browsers | Firefox, Chromium |
| Fonts | Noto, Liberation, CaskaydiaCove Nerd Font |
| Tools | htop, btop, tree, jq, xclip |
| Shell | zsh (set as default) |

Plus your dotfiles (if `--dotfiles` specified).

## Daily Commands

```
start <label>      Create/start VM and SSH in
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
kodemachine start work
# ... code ...
kodemachine suspend work   # Instant pause
kodemachine start work     # Instant resume

# Multiple projects (concurrent)
kodemachine start api
kodemachine start frontend
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
  "shared_disk": "Shared/projects-luks.qcow2"
}
```

| Key | Description |
|-----|-------------|
| `base_image` | Golden image name in UTM |
| `ssh_user` | SSH username |
| `prefix` | Clone name prefix |
| `headless` | Hide VM window |
| `shared_disk` | Shared disk path (relative to UTM docs) |

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

## Integration with Dotfiles

Kodemachine works with your dotfiles repo:

1. **create-base.rb** clones your dotfiles and runs `bootstrap.sh`
2. All clones inherit the configured environment
3. Update dotfiles in base image: `kodemachine start base`

Recommended dotfiles structure:
```
dotfiles/
├── bootstrap.sh    # CLI tools, shell config, editor
└── ...
```

Keep GUI-specific setup in create-base.rb, not bootstrap.sh.
This keeps bootstrap.sh portable across Mac, Linux, servers.

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
      "start resume stop suspend delete status list attach doctor" \
      -- "$cur"))
  elif [[ "$cmd" =~ ^(start|stop|suspend|delete|status|attach)$ ]]; then
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
  -a "start resume stop suspend delete status list attach doctor"
complete -c kodemachine -n "__fish_seen_subcommand_from start stop suspend delete status attach" \
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

- **No gem dependencies**: All scripts use Ruby standard library only (`json`, `fileutils`, `open3`, `optparse`). Works with macOS system Ruby.
- **No Brewfile**: Dependencies (UTM, qemu) installed imperatively by setup-host.rb.
- **Stateless scripts**: No daemon, no database. Config is a single JSON file.

## License

MIT
