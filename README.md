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

## Requirements

- macOS (Apple Silicon or Intel)
- [UTM](https://mac.getutm.app/)
- Ruby (included with macOS)

## Install

```bash
git clone https://github.com/yourusername/kodemachine.git
cd kodemachine
ln -s $PWD/kodemachine.rb /usr/local/bin/kodemachine
chmod +x kodemachine.rb
```

## Base Image Setup

Kodemachine clones from a "golden image". Create one:

1. Download [Ubuntu 24.04 ARM64](https://ubuntu.com/download/server/arm)
2. Create VM in UTM named `kodeimage-v0.1.0`
3. Install Ubuntu
4. Inside the VM:

```bash
# Guest agent (required for IP discovery)
sudo apt update && sudo apt install -y qemu-guest-agent
sudo systemctl enable qemu-guest-agent

# Unique IDs for clones (required)
sudo truncate -s 0 /etc/machine-id

# SSH key
mkdir -p ~/.ssh
echo "your-public-key" >> ~/.ssh/authorized_keys
```

5. Shut down. Done.

## Commands

```
start <label>      Create/start VM and SSH in
start base         Start base image directly (for modifications)
resume <label>     Alias for start
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

## Usage

```bash
# Daily workflow
kodemachine start work
# ... code ...
kodemachine suspend work

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
  "base_image": "kodeimage-v0.1.0",
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

## Architecture

```
┌─────────────────────────────────────┐
│            CLI Layer                │
│  - Argument parsing                 │
│  - User feedback                    │
│  - SSH handoff                      │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│          Manager Layer              │
│  - APFS CoW cloning                 │
│  - MAC address generation           │
│  - Shared disk injection            │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│            VM Layer                 │
│  - State via utmctl                 │
│  - IP via guest agent               │
│  - Resource stats                   │
└─────────────────────────────────────┘
```

Key decisions:

- **Pure Ruby** - No gems, uses macOS system Ruby
- **Guest Agent** - Dynamic IP discovery
- **APFS CoW** - Instant clones, zero initial disk
- **Random MACs** - Unique DHCP leases per clone

See [CORE.md](CORE.md) for details.

## Troubleshooting

**SSH fails after start**
```bash
kodemachine attach <label>
# Check: systemctl status qemu-guest-agent
```

**IP conflicts with base image**
- Stop all clones before starting base
- Older clones may share MAC addresses

**"Device busy" errors**
- Force quit UTM, retry

**OSStatus -1712 / -10004**
- Apple Events timeout during I/O
- Usually transient, script retries

## License

MIT
