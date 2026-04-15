# State: Multi-platform support

## What was done

### Branch: `multi-platform` (off master)

1. **kodemachine.rb** — Full refactor with backend abstraction pattern
   - `UtmBackend` (macOS): utmctl + APFS clones + plist — preserves original behavior
   - `LibvirtBackend` (Linux): virsh + qcow2 backing files + libvirt XML (REXML)
   - `VM`, `Manager`, `CLI` are now platform-agnostic
   - New `doctor` command implemented for both platforms
   - All syntax checked, `doctor`/`list`/`status` smoke-tested on Ubuntu

2. **setup-host.rb** — Split into `MacosSetup` and `LinuxSetup`
   - Linux: checks KVM, libvirt, virsh, qemu-img, group membership, default network
   - Creates `kodemachine` libvirt storage pool at `~/.local/share/kodemachine/images/`
   - Not yet run (user hasn't executed it)

3. **create-base.rb** — Platform-aware provisioning
   - Linux: uses virsh for VM discovery/IP/status, REXML for rename
   - Adds serial console setup (serial-getty@ttyS0 + GRUB) for Linux guests
   - SSH provisioning unchanged (already portable)

4. **README.md** + **CORE.md** — Updated for multi-platform

5. **koder/plans/01_multi_platform.md** — Implementation plan (completed)

## What's NOT done yet

### Immediate next steps (to get a working VM on this machine)

1. Run `./setup-host.rb` — creates the storage pool
2. Create a base Ubuntu VM:
   ```bash
   virt-install \
     --name ubuntu-base \
     --ram 4096 \
     --vcpus 4 \
     --disk size=32 \
     --os-variant ubuntu22.04 \
     --location https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso \
     --network network=default \
     --graphics none \
     --console pty,target_type=serial \
     --extra-args 'console=ttyS0,115200n8'
   ```
3. Run `./create-base.rb` — provisions and renames to kodeimage
4. `kodemachine start test` — first real end-to-end test

### Testman integration (discussed, not started)

- Testman (~/Projects/testman) builds container images for AI agent sandboxing
- Its Containerfile is ARM64-only — needs adaptation for x86_64
- Three options discussed: adapt Containerfile, use standard image, or run inside kodemachine VM
- User hasn't decided which approach yet

## Host machine details

- AMD Ryzen 7 3700X, Ubuntu 22.04, x86_64, ext4
- KVM, libvirt 8.0, virsh, qemu-img, virt-manager, virt-install all installed
- User is in libvirt group, default network is active
- Storage pool NOT yet created (setup-host.rb not run)
- No base VM exists yet

## Key design decisions made

- qcow2 backing files for instant CoW clones (works on ext4, no btrfs/zfs needed)
- `~/.local/share/kodemachine/images/` as storage path (user-writable, avoids AppArmor issues)
- Guest exec via SSH (not virsh qemu-agent-command — simpler, already works)
- x86_64 guests on this machine (not arm64 — emulation would be unusable)
- NAT networking by default on Linux (bridged requires host bridge setup)
- `SecureRandom.uuid` replaces backtick `uuidgen` (cross-platform)
- REXML (Ruby stdlib) for libvirt XML manipulation
