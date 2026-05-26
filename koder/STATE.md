# State: Multi-platform support

## What was done

### Branch: `multi-platform` (off master)

1. **kodemachine.rb** — Full refactor with backend abstraction pattern
   - `UtmBackend` (macOS): utmctl + APFS clones + plist — preserves original behavior
   - `LibvirtBackend` (Linux): virsh + qcow2 backing files + libvirt XML (REXML)
   - `VM`, `Manager`, `CLI` are now platform-agnostic
   - `doctor`, `list`, `status`, clone/start/stop/delete smoke-tested on Ubuntu
   - Fixed Linux IP detection to ignore guest-agent loopback (`127.0.0.1`)
   - Fixed libvirt qcow2 backing-chain XML so clones actually boot from the base backing file
   - Linux shared disk no longer uses `<shareable>` for qcow2 (libvirt rejects that)
   - `start` now polls IP and SSH together, so stale libvirt DHCP leases do not cause SSH timeout
   - Starting clones is blocked while `base` is running; clones use the base qcow2 as backing storage and require the base to be shut off
   - Commits:
     - `1061fa9 Add Linux libvirt support`
     - `2d9faf3 Guard Linux clones while base is running`
     - `284b0c9 Use MAC-based DHCP IDs for Linux clones`

2. **setup-host.rb** — Split into `MacosSetup` and `LinuxSetup`
   - Linux: checks KVM, libvirt, virsh, qemu-img, ACL tools, group membership, default network
   - Creates `kodemachine` libvirt storage pool at `~/.local/share/kodemachine/images/`
   - Creates sparse Linux shared disk `Shared/projects-luks.qcow2` (64GB) if missing
   - Applies ACLs so `libvirt-qemu`/`qemu` can traverse user-owned image storage
   - Falls back to `~/.local/bin/kodemachine` symlink when `/usr/local/bin` requires sudo/non-TTY
   - Run successfully on this machine

3. **create-base.rb** — Platform-aware provisioning
   - Linux: uses virsh for VM discovery/IP/status, REXML for rename
   - Adds serial console setup (`serial-getty@ttyS0` + GRUB) for Linux guests
   - Installs Podman + rootless container prerequisites in the guest (no Docker daemon)
   - Configures netplan DHCP with `dhcp-identifier: mac` so clones with new MACs get unique leases
   - Configures ssh.service override to regenerate missing SSH host keys before `sshd -t`
   - Clears SSH host keys only in the final shutdown command so subsequent SSH commands don't break
   - Uses `sudo sh -c ...` wrapping so compound sudo commands run as root

4. **README.md** + **CORE.md** — Updated for multi-platform
   - Documented native architecture choice: ARM64 on Apple Silicon, x86_64/amd64 on x86 Linux
   - Documented `#!/usr/bin/env ruby` approach: no mise requirement, no hardcoded `/usr/bin/ruby`

5. **Base image personalization** — Done manually for this user on this machine
   - Base image: `kodeimage-v2026.05`
   - Copied local `~/dotfiles` working tree into base VM as `/home/kodeman/dotfiles`
     - This included local uncommitted dotfiles changes at the time of copy
   - Ran `~/dotfiles/bootstrap.sh start` in the base image
   - Installed Linuxbrew and user tooling in base:
     - zsh, tmux, neovim, mise, bat, ripgrep, fd, httpie, tree, htop, etc.
   - Created dotfile symlinks in base:
     - `~/.zshrc`, `~/.tmux.conf`, `~/.config/nvim`, `~/.config/alacritty`
   - Installed nvim plugins and fonts where available
   - Customized prompt inside base dotfiles:
     - `~/dotfiles/prompts/lino/index.zsh`
     - Fresh clones show `[vm:<label>] ➜`
     - Example: `km-labelcheck` showed `[vm:labelcheck] ➜`
     - Base shows `[vm:base] ➜`
   - Did **not** run `mise install` yet; runtimes in `.tool-versions` remain not fully baked

6. **Project clone: clawman** — Created for Peter Steinberg/openclaw experiments
   - VM: `km-clawman`
   - Created from `kodeimage-v2026.05`
   - Shared disk attached
   - Installed `gogcli` in `clawman` only (not base):
     - `brew install openclaw/tap/gogcli`
     - Version verified: `v0.19.0 (b25a3c0 2026-05-22T15:53:00Z)`
   - Added user-level symlink inside `clawman`:
     - `~/.local/bin/gog -> /home/linuxbrew/.linuxbrew/bin/gog`
   - Verified with interactive zsh that `gog --version` works
   - Note: there was a typo clone `claman`; it caused confusion/IP overlap and should not be used. Keep/use `clawman`.

7. **koder/plans/01_multi_platform.md** — Implementation plan (completed)

## Current machine setup status

- Host setup completed via `./setup-host.rb`
- `kodemachine` symlink created at `~/.local/bin/kodemachine`
- Libvirt storage pool active:
  - `kodemachine` -> `~/.local/share/kodemachine/images/`
- Base image exists and is shut off unless explicitly started:
  - `kodeimage-v2026.05`
  - Ubuntu 24.04 cloud image, amd64/x86_64
  - 4 vCPU, 4GB RAM
  - 32GB qcow2 base disk
  - Podman installed and tested in clone
  - Dotfiles baked into base
- Shared persistent disk exists:
  - `~/.local/share/kodemachine/images/Shared/projects-luks.qcow2`
  - 64GB sparse qcow2
  - Not yet LUKS-formatted inside a VM
- `kodemachine doctor` is all green on Linux
- Active/useful clone:
  - `clawman` / `km-clawman` for openclaw/Peter Steinberg experiments

## Validation completed

1. Created Ubuntu 24.04 amd64 base from cloud image + NoCloud seed
2. Ran `./create-base.rb --skip-gui --skip-browsers`
3. Repaired/validated Linux clone requirements:
   - MAC-based netplan DHCP (`dhcp-identifier: mac`)
   - SSH host key regeneration
   - qcow2 backing-chain XML
   - SSH readiness wait
   - shared qcow2 disk attach
4. Smoke tests passed:
   - `kodemachine start smoke --no-disk`
   - `kodemachine start diskcheck` with shared disk attached as `/dev/vdb`
   - `kodemachine start dotcheck --no-disk` after dotfiles bake
   - `kodemachine start labelcheck --no-disk` after prompt customization
   - `kodemachine start clawman` after stopping base
   - SSH login works
   - hostname injection works (`km-<label>`)
   - prompt label works (`[vm:<label>] ➜`)
   - Podman hello-world works inside clone
   - stop/delete works
5. Test clones were deleted after validation, except `clawman` which is intentionally kept

## Important operational notes

### Base vs clones

- `kodemachine start base` starts the golden image directly.
- Changes made in `base` are inherited by future clones.
- Existing clones are not updated by later base changes.
- Do **not** run or create clones while `base` is running.
  - The code now blocks starting clones if `base` is running.
  - Stop base first:
    ```bash
    kodemachine stop base
    kodemachine start clawman
    ```

### Prompt label

Fresh clones should show:

```text
[vm:<label>] ➜
```

Examples:

```text
[vm:clawman] ➜
[vm:base] ➜
```

### gogcli in clawman

Inside `clawman`:

```bash
gog --version
```

Expected:

```text
v0.19.0 (b25a3c0 2026-05-22T15:53:00Z)
```

If `gog` is missing in a shell, check:

```bash
ls -l ~/.local/bin/gog
/home/linuxbrew/.linuxbrew/bin/gog --version
```

`gogcli` is installed in `clawman` only, not in `base`. If every future VM should have it, install `gogcli` in `base` later.

## What's NOT done yet

### LUKS shared disk formatting

The shared disk file exists, but it still needs to be initialized from inside a VM:

```bash
kodemachine start setup-luks
lsblk   # verify /dev/vdb
sudo cryptsetup luksFormat /dev/vdb
sudo cryptsetup luksOpen /dev/vdb projects
sudo mkfs.ext4 /dev/mapper/projects
sudo mkdir -p /mnt/projects
sudo mount /dev/mapper/projects /mnt/projects
sudo chown $USER:$USER /mnt/projects
```

### Testman integration

- Testman (`~/Projects/testman`) builds container images for AI agent sandboxing
- Its build script currently forces `--platform linux/arm64`
- For this Ubuntu/Ryzen host it should build/run native `linux/amd64`, not ARM64 emulation
- Recommended next Testman work:
  - make platform dynamic (`arm64` on Apple Silicon, `amd64` on x86_64 Linux)
  - keep Podman-only workflow; do not introduce Docker daemon dependency
  - test `agentman` inside a kodemachine VM against a project directory on the LUKS disk

### Base runtime installs

- Dotfiles are baked in, but `mise install` was not run.
- `.tool-versions` includes Node, Ruby, Python, Rust, Go, Bun, Swift.
- Decide later whether to bake all runtimes into `base` or install per project/clone.

## Host machine details

- AMD Ryzen 7 3700X, Ubuntu 22.04, x86_64, ext4
- KVM, libvirt 8.0, virsh, qemu-img, virt-manager, virt-install all installed
- User is in libvirt group, default network is active
- Podman installed on host and in the VM base, but Docker is not required by kodemachine

## Key design decisions made

- qcow2 backing files for instant CoW clones (works on ext4, no btrfs/zfs needed)
- `~/.local/share/kodemachine/images/` as storage path (user-writable, with ACLs for libvirt QEMU access)
- Guest exec via SSH for normal operation (qemu guest agent only used manually for recovery/debug)
- x86_64 guests on this machine (not arm64 — emulation would be unusable)
- NAT networking by default on Linux (bridged requires host bridge setup)
- `SecureRandom.uuid` replaces backtick `uuidgen` (cross-platform)
- REXML (Ruby stdlib) for libvirt XML manipulation
- `#!/usr/bin/env ruby` keeps support for system Ruby, Homebrew Ruby, mise, rbenv, asdf, etc.
