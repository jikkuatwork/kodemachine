This document outlines the architecture and philosophy of **kodemachine**, a Ruby-based orchestration layer for ephemeral VMs on macOS (UTM) and Linux (libvirt/KVM).

---

## 1. Philosophy: The "Disposable Compute" Model

Modern development often leads to "configuration drift," where local environments become cluttered with stale dependencies. **kodemachine** treats virtual machines not as long-lived servers, but as **ephemeral, isolated execution contexts**.

* **Immutable Base:** The "Golden Image" (`kodeimage-vX.Y.Z`) remains untouched.
* **Copy-on-Write Workflows:** Every project gets a fresh clone.
* **Headless-First:** The VM should feel like a native background service, not a separate windowed OS.

---

## 2. Design Decisions

### Language: Pure Ruby

Chosen for its presence on macOS (`/usr/bin/ruby`) and Linux (system Ruby). By avoiding external Gems and version managers (like `asdf`), the tool achieves **zero-dependency portability**. It utilizes the standard library's `OptionParser`, `JSON`, `FileUtils`, `REXML`, and `SecureRandom`.

### Multi-Platform: Backend Abstraction

Platform-specific logic is encapsulated in backend classes:

* **UtmBackend** (macOS): Uses `utmctl` CLI, APFS copy-on-write clones, and plist manipulation.
* **LibvirtBackend** (Linux): Uses `virsh` CLI, qcow2 backing files for instant clones, and libvirt XML domain definitions.

The platform is detected at runtime via `RUBY_PLATFORM`. The CLI, Manager, and VM classes are platform-agnostic — they call backend methods for all hypervisor-specific operations.

### Communication: The Guest Agent Bridge

Rather than relying on brittle networking assumptions or static IPs, the tool queries the **QEMU Guest Agent**:

* **macOS:** Via `utmctl ip-address` and `utmctl exec`.
* **Linux:** Via `virsh domifaddr --source agent` and SSH for command execution.

This allows:

1. **Dynamic Discovery:** Identifying the IP address post-boot without ARP scanning.
2. **Personality Injection:** Dynamically setting the internal `hostname` to match the clone's label.

### State Management: XDG Standards

Configuration is stored in `~/.config/kodemachine/config.json`. This separates the tool's logic from the user's local environment, allowing for versioned base-image switching without code changes.

---

## 3. Architecture

The system is built on a four-tier Object-Oriented model:

| Layer | Responsibility |
| --- | --- |
| **Backend** | Platform-specific hypervisor operations (UtmBackend or LibvirtBackend). |
| **CLI** | Argument parsing, user feedback, and SSH execution. |
| **Manager** | Orchestrating lifecycle (cloning, starting, stopping) via backend. |
| **VM** | A state-object representing a single instance (delegates to backend). |

---

## 4. The Technical Workflow

### Image Baking

1. Install **Ubuntu 24.04 LTS** (ARM64 on macOS, x86_64 on Linux).
2. Install `qemu-guest-agent` and enable the service.
3. Configure SSH with your public key.
4. **Crucial:** Truncate `/etc/machine-id` so clones generate unique D-Bus/DHCP IDs.
5. (Linux) Enable serial console (`serial-getty@ttyS0`) for `virsh console` access.

### Lifecycle of a Spawn

1. **Request:** User runs `kodemachine project-alpha`.
2. **Check:** Script verifies if `km-project-alpha` exists; if not, it triggers a clone.
   - macOS: APFS copy-on-write via `cp -Rc`
   - Linux: qcow2 backing file via `qemu-img create -b`
3. **Bootstrap:** The VM is started headlessly.
4. **Polling:** The script enters a retry loop, querying the Guest Agent for an IP address.
5. **Handoff:** Once an IP is detected, the script executes `exec ssh`, replacing the Ruby process with an active SSH session.

---

## 5. Platform-Specific Error Handling

### macOS: OSStatus Errors (-10004 / -1712)

Communication between the CLI (`utmctl`) and the UTM background process occurs via Apple Events. Under heavy I/O (like cloning a 20GB image), macOS may return a timeout error (`-1712`) or a privilege/interrupt error (`-10004`).

**Design Mitigation:**

* The script treats these errors as **non-fatal**.
* It implements a "Verification Loop" that checks the actual VM state after a start command, regardless of the returned exit code.

### Linux: libvirt/virsh

Communication uses the `virsh` CLI against `qemu:///system`. Errors are generally deterministic (e.g., domain not found, permission denied). The libvirt group membership and storage pool setup (via `setup-host.rb`) prevent most common permission issues.

---

## 6. Usage & Maintenance

* **Update Base:** Create a new VM, rename it to `kodeimage-v0.2.0`, and update the `config.json`.
* **Cleanup:** Ephemeral clones can be listed via `kodemachine list` and purged to reclaim disk space.
* **Rescue:** If networking fails, `kodemachine attach <label>` provides a direct serial pipe to the guest.

