# LUKS Drive Setup for Kodemachine

## Overview

- Kodemachine uses a shared LUKS-encrypted disk for projects
- The disk persists across ephemeral VM clones
- Only the LUKS disk survives VM deletion

## Prerequisites

- Kodemachine installed and working
- A VM running via `kodemachine <label>`
- The shared disk visible as `/dev/vdb` inside VM

## Creating the LUKS Volume

### 1. Start a VM

```bash
kodemachine setup-luks
```

### 2. Verify disk is attached

```bash
lsblk | grep vdb
# Should show: vdb  253:16  0  10G  0  disk
```

### 3. Format with LUKS

**Option A: Fast/Sparse (recommended for most users)**

```bash
sudo cryptsetup luksFormat /dev/vdb
```

- Instant, disk stays sparse (~200MB on host)
- Good security for typical threat models
- Use this unless you have specific high-security needs

**Option B: Secure/Full (high-security scenarios)**

```bash
# Format with strong KDF
sudo cryptsetup luksFormat --type luks2 --pbkdf argon2id /dev/vdb

# Open it
sudo cryptsetup luksOpen /dev/vdb projects

# Fill with zeros (encrypts as random data) - SLOW
sudo dd if=/dev/zero of=/dev/mapper/projects bs=1M status=progress

# Close and reopen to continue setup
sudo cryptsetup luksClose projects
sudo cryptsetup luksOpen /dev/vdb projects
```

- Takes minutes (writes entire 10GB)
- Disk file grows to full size on host
- Hides which sectors contain real data
- Required for: sensitive data, compliance, physical theft concerns

**For both options:**

- Enter `YES` (uppercase) to confirm
- Choose a strong password
- Remember this password - no recovery possible without it

### 4. Open the encrypted volume

```bash
sudo cryptsetup luksOpen /dev/vdb projects
```

- Enter your password
- Creates `/dev/mapper/projects`

### 5. Create filesystem

```bash
sudo mkfs.ext4 /dev/mapper/projects
```

### 6. Mount and set permissions

```bash
sudo mkdir -p /mnt/projects
sudo mount /dev/mapper/projects /mnt/projects
sudo chown $USER:$USER /mnt/projects
```

## Daily Usage

### Opening (after VM start)

```bash
sudo cryptsetup luksOpen /dev/vdb projects
sudo mount /dev/mapper/projects /mnt/projects
```

### Closing (before VM stop) - Optional

```bash
sudo umount /mnt/projects
sudo cryptsetup luksClose projects
```

- Not strictly required - VM shutdown handles this
- Good practice for data integrity

## Automation (Optional)

Add to `~/.bashrc` in the VM for auto-prompt on login:

```bash
if [ -b /dev/vdb ] && [ ! -b /dev/mapper/projects ]; then
    echo "LUKS drive detected. Unlock? (y/n)"
    read -r answer
    if [ "$answer" = "y" ]; then
        sudo cryptsetup luksOpen /dev/vdb projects
        sudo mount /dev/mapper/projects /mnt/projects
        echo "Mounted at /mnt/projects"
    fi
fi
```

## Troubleshooting

### "Device /dev/vdb not found"

- Ensure VM was started with kodemachine (not UTM directly)
- Check: `lsblk` to see available disks
- Verify shared_disk config in kodemachine.rb

### "No key available with this passphrase"

- Wrong password
- LUKS header corrupted (data lost, recreate volume)

### "Device or resource busy" on unmount

- Close all files/terminals using /mnt/projects
- Run: `lsof +D /mnt/projects` to find open files

## Security Notes

- LUKS password is required every VM session
- No password recovery - backup important data
- The qcow2 file on host is encrypted at rest
- Fast format (default) is sufficient for most use cases
- Full-disk wipe only needed for high-security scenarios

## File Locations

| Item | Path |
|------|------|
| Shared disk (host) | `~/Library/.../UTM/Data/Documents/Shared/` |
| Mount point (VM) | `/mnt/projects` |
| Device (VM) | `/dev/vdb` |
| Mapper (VM) | `/dev/mapper/projects` |
