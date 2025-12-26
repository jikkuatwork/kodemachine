This document outlines the architecture and philosophy of **kodemachine**, a Ruby-based orchestration layer for UTM/QEMU on macOS.

---

## 1. Philosophy: The "Disposable Compute" Model

Modern development often leads to "configuration drift," where local environments become cluttered with stale dependencies. **kodemachine** treats virtual machines not as long-lived servers, but as **ephemeral, isolated execution contexts**.

* **Immutable Base:** The "Golden Image" (`kodeimage-vX.Y.Z`) remains untouched.
* **Copy-on-Write Workflows:** Every project gets a fresh clone.
* **Headless-First:** The VM should feel like a native background service, not a separate windowed OS.

---

## 2. Design Decisions

### Language: Pure Ruby

Chosen for its presence in macOS (`/usr/bin/ruby`). By avoiding external Gems and version managers (like `asdf`), the tool achieves **zero-dependency portability**. It utilizes the standard library's `OptionParser`, `JSON`, and `FileUtils`.

### Communication: The Guest Agent Bridge

Rather than relying on brittle networking assumptions or static IPs, the tool queries the **QEMU Guest Agent** via `utmctl`. This allows:

1. **Dynamic Discovery:** Identifying the IP address post-boot without ARP scanning.
2. **Personality Injection:** Dynamically setting the internal `hostname` to match the clone's label.

### State Management: XDG Standards

Configuration is stored in `~/.config/kodemachine/config.json`. This separates the tool's logic from the user's local environment, allowing for versioned base-image switching without code changes.

---

## 3. Architecture

The system is built on a three-tier Object-Oriented model:

| Layer | Responsibility |
| --- | --- |
| **CLI** | Argument parsing, user feedback, and SSH execution. |
| **Manager** | Orchestrating `utmctl` (cloning, starting, stopping). |
| **VM** | A state-object representing a single instance (calculating size, status, and IP). |

---

## 4. The Technical Workflow

### Image Baking

1. Install **Ubuntu 24.04 LTS (ARM64)**.
2. Install `qemu-guest-agent` and enable the service.
3. Configure SSH with your public key.
4. **Crucial:** Truncate `/etc/machine-id` so clones generate unique D-Bus/DHCP IDs.

### Lifecycle of a Spawn

1. **Request:** User runs `kodemachine project-alpha`.
2. **Check:** Script verifies if `km-project-alpha` exists; if not, it triggers a `utmctl clone`.
3. **Bootstrap:** The VM is started in `--detach` mode.
4. **Polling:** The script enters a retry loop, querying the Guest Agent for an IP address.
5. **Handoff:** Once an IP is detected, the script executes `exec ssh`, replacing the Ruby process with an active SSH session.

---

## 5. Handling OSStatus Errors (-10004 / -1712)

Communication between the CLI (`utmctl`) and the UTM background process occurs via Apple Events. Under heavy I/O (like cloning a 20GB image), macOS may return a timeout error (`-1712`) or a privilege/interrupt error (`-10004`).

**Design Mitigation:**

* The script treats these errors as **non-fatal**.
* It implements a "Verification Loop" that checks the actual VM state after a start command, regardless of the returned exit code.

---

## 6. Usage & Maintenance

* **Update Base:** Create a new VM, rename it to `kodeimage-v0.2.0`, and update the `config.json`.
* **Cleanup:** Ephemeral clones can be listed via `kodemachine list` and purged to reclaim disk space.
* **Rescue:** If networking fails, `kodemachine attach <label>` provides a direct serial pipe to the guest.

Would you like me to generate a **README.md** formatted specifically for a GitHub repository including these technical details?