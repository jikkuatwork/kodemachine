# Plan: Multi-platform support (Linux + macOS)

## Context

Kodemachine is a macOS-only ephemeral VM manager using UTM/APFS. The user has two machines — M4 Air (macOS, travel) and Ryzen 3700X (Ubuntu 22.04, primary desktop) — and wants platform equivalence. The Linux machine already has libvirt, virsh, qemu-img, and KVM installed. We'll add Linux support via a backend abstraction pattern, keeping macOS behavior unchanged.

**Branch:** `multi-platform` (master stays macOS-only)

## Architecture: Backend Module Pattern

Refactor the three-tier model (CLI → Manager → VM) to route all platform-specific calls through a Backend interface. Two implementations:

- `UtmBackend` — existing macOS logic (utmctl + APFS clones + plist)
- `LibvirtBackend` — new Linux logic (virsh + qcow2 backing files + libvirt XML)

Platform detected at runtime via `RUBY_PLATFORM`.

### Backend Interface Methods

```
list_vms, vm_exists?, vm_status, vm_ip
start_vm, stop_vm, suspend_vm, resume_vm, delete_vm, attach_vm
clone_base(base, clone, opts)
set_bridged_network, set_nat_network
guest_exec(name, cmd)
vm_cpu_count, vm_memory_mb, vm_storage_path, vm_disk_files
images_dir, qemu_img_path
has_display?, has_shared_disk?
find_vm_by_pattern, rename_vm
```

### Key Linux Mappings

| macOS | Linux |
|-------|-------|
| `utmctl list/status/start/stop/suspend/delete` | `virsh list --all / domstate / start / shutdown / suspend / undefine` |
| APFS `cp -Rc` | `qemu-img create -f qcow2 -b base.qcow2 -F qcow2 clone.qcow2` |
| plist XML manipulation | libvirt domain XML template + REXML (stdlib) |
| `utmctl ip-address` | `virsh domifaddr --source agent` (fallback: `--source lease`) |
| `utmctl exec --cmd` | SSH to VM (simpler than `virsh qemu-agent-command`) |
| `utmctl attach` | `virsh console` |
| `~/Library/Containers/com.utmapp.UTM/Data/Documents` | `~/.local/share/kodemachine/images/` |
| `open -a UTM path.utm` | `virsh define domain.xml` |
| `/opt/homebrew/bin/qemu-img` | `/usr/bin/qemu-img` |

### Linux-specific Details

- **Storage:** `~/.local/share/kodemachine/images/` with a libvirt storage pool (avoids AppArmor/permissions issues)
- **Network:** NAT via `default` network; bridged requires host bridge (`br0`) setup
- **Domain XML:** Template-based (KVM, q35, host-passthrough CPU, virtio disk/net, guest agent channel, serial console)
- **Guest arch:** x86_64 on this machine (not arm64 — emulation would be unusable)
- **`File.birthtime`:** Not available on ext4 — fallback to `File.mtime`
- **Serial console:** Add `serial-getty@ttyS0` and grub console config in create-base provisioning
- **UUID generation:** Switch from backtick `uuidgen` to `SecureRandom.uuid` (Ruby stdlib, cross-platform)

## Implementation Steps

### Step 1: Branch + kodemachine.rb refactor

- Create `multi-platform` branch
- Add `detect_platform`, `create_backend` factory
- Extract `UtmBackend` class (move all utmctl/plist/APFS code from VM, Manager, CLI)
- Make VM and Manager accept backend parameter
- Add `LibvirtBackend` class with full implementation
- Wire CLI to use backend
- Handle `File.birthtime` fallback

**Files:** `kodemachine.rb`

### Step 2: setup-host.rb

- Add platform detection
- Add `LinuxSetup` class: check KVM, libvirt, virsh, qemu-img, libvirt group, default network, create storage pool
- Keep `MacosSetup` (rename current class)

**Files:** `setup-host.rb`

### Step 3: create-base.rb

- Add platform detection + backend parameter to Builder
- Platform-branch: prerequisites, VM discovery, IP detection, finalize/rename
- Add serial console provisioning (grub + serial-getty) for Linux guests
- SSH provisioning stays unchanged

**Files:** `create-base.rb`

### Step 4: Documentation

- Update README.md with Linux section
- Update CORE.md to reflect Backend pattern

**Files:** `README.md`, `CORE.md`

## Verification

1. `./setup-host.rb` — should detect Linux, check KVM/libvirt, create storage pool
2. `kodemachine doctor` — should report system health on Linux
3. `kodemachine list` — should show VMs (empty initially)
4. Create a base VM manually in virt-manager, then `./create-base.rb` to provision it
5. `kodemachine start test` — clone + boot + SSH in
6. `kodemachine suspend test` / `kodemachine start test` — pause/resume
7. `kodemachine status test` — live stats via SSH
8. `kodemachine delete test` — clean removal

## Critical Files

- `kodemachine.rb` — primary refactor target (~765 lines, becomes ~1000 with LibvirtBackend)
- `setup-host.rb` — add LinuxSetup (~200 lines → ~300)
- `create-base.rb` — platform-branch prerequisites/finalize (~565 lines → ~650)
