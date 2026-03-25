# VMware vSphere/ESXi OVA Conversion

## Overview

While the CI/CD pipeline publishes Vagrant `.box` artifacts for VMware Desktop, these are essentially compressed VMware Workstation-style VMs. They can be converted into `.ova` templates compatible with **vSphere/ESXi** using VMware's official `ovftool`.

This document provides a complete, step-by-step guide on how to perform this conversion on an **AlmaLinux 9** or **AlmaLinux 10** system.

## Prerequisites

| Tool | Description |
|------|-------------|
| `ovftool` | VMware OVF Tool (the script can install it automatically from a `.zip`) |
| `qemu-img` | QEMU disk image utility (from `qemu-img` package) |
| `libguestfs` / `virt-customize` | Tools for modifying virtual disk images |
| `tar`, `unzip` | Standard archive utilities |

## Step 1: Download `ovftool`

Download the Linux `.zip` version of the OVF Tool from the Broadcom Developer Portal:

https://developer.broadcom.com/tools/open-virtualization-format-ovf-tool/latest

Place the downloaded `.zip` file in your working directory. The conversion script (below) will detect and install it automatically if `ovftool` is not already in your `$PATH`.

## Step 2: Download the Vagrant `.box` File

Download the specific Vagrant VMware box version you need from Vagrant Cloud:

https://portal.cloud.hashicorp.com/vagrant/discover/almalinux

> **Note:** Vagrant Cloud may serve box files as raw UUIDs without file extensions when downloaded via API or direct links (e.g., `f5952274-22f3-11f1-9947-be8f8dec9788`). This is normal — the file is still a valid `.box` (gzip-compressed tar archive).

## Step 3: Create the Conversion Script

Create a script called `box2ova.sh` that automates the extraction, cloud-init adjustment, and OVA conversion:

```bash
cat << 'EOF' > box2ova.sh
#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <path-to-box-file>"
    exit 1
fi

BOX_FILE="$1"
HW_VERSION="20" # ESXi 8.0 U1 compatible

echo "🛠️  Step 1: Installing required system packages..."
EXTRA_PKGS=""
if [ -f /etc/os-release ]; then
    source /etc/os-release
    # Detect EL10 (AlmaLinux/RHEL/Rocky 10) to install legacy crypt libs required by ovftool
    if [[ "${VERSION_ID%%.*}" == "10" ]]; then
        echo "ℹ️  EL10 detected, adding 'libxcrypt-compat' for ovftool compatibility..."
        EXTRA_PKGS="libxcrypt-compat"
    fi
fi
sudo dnf install -y libguestfs guestfs-tools libnsl qemu-img unzip $EXTRA_PKGS

echo "🛠️  Step 2: Checking ovftool installation..."
if ! command -v ovftool &> /dev/null; then
    echo "⚠️  'ovftool' not found in PATH."
    ZIP_FILE=$(ls VMware-ovftool-*-lin.x86_64.zip 2>/dev/null | head -n 1)

    if [ -z "$ZIP_FILE" ]; then
        echo "❌ Error: OVF Tool is not installed and no installation .zip was found."
        echo "Please download the 'OVF Tool for Linux Zip' from Broadcom."
        echo "Place the downloaded .zip file in this directory and run this script again."
        exit 1
    fi

    echo "📦 Unpacking $ZIP_FILE to /opt/..."
    sudo unzip -q "$ZIP_FILE" -d /opt/

    echo "🔗 Linking ovftool to /usr/local/bin/..."
    sudo ln -s /opt/ovftool/ovftool /usr/local/bin/ovftool
    echo "✅ ovftool successfully installed."
else
    echo "✅ ovftool is already installed."
fi

TMP_DIR=$(mktemp -d)
trap 'echo "🧹 Cleaning up..."; rm -rf "$TMP_DIR"' EXIT

echo "📦 Step 3: Extracting '$BOX_FILE'..."
tar -xf "$BOX_FILE" -C "$TMP_DIR"

VMX_FILE=$(find "$TMP_DIR" -name "*.vmx" ! -name "._*" | head -n 1)
VMDK_FILE=$(find "$TMP_DIR" -name "*.vmdk" ! -name "*-s[0-9]*.vmdk" ! -name "*-flat.vmdk" ! -name "._*" | head -n 1)

if [ -z "$VMDK_FILE" ] || [ -z "$VMX_FILE" ]; then
    echo "Error: Could not find the main .vmdk or .vmx file!"
    exit 1
fi

echo "🔍 Step 4: Determining clean template name from VMX metadata..."
RAW_NAME=$(grep -i '^displayname[[:space:]]*=' "$VMX_FILE" | cut -d '"' -f 2 | tr -d '\r' || true)

if [ -z "$RAW_NAME" ]; then
    RAW_NAME=$(basename "$BOX_FILE" .box)
fi

CLEAN_NAME=$(echo "$RAW_NAME" | sed -e 's/-[Vv]agrant//g' -e 's/[Vv]agrant-//g' -e 's/[Vv]agrant//g')
OUTPUT_OVA="${CLEAN_NAME}.ova"
echo "🏷️  Target OVA name will be: $OUTPUT_OVA"

echo "🔄 Step 5: Converting VMDK to RAW format for safe editing..."
qemu-img convert -O raw "$VMDK_FILE" "${VMDK_FILE}.raw"

echo "🛠️  Step 6: Modifying virtual disk internally to re-enable cloud-init networking..."
# Running as root via sudo env to avoid strict kernel read permissions on newer OSs (e.g., EL10).
# Setting MEMSIZE to 768 to prevent Out-Of-Memory kills on smaller build servers.
sudo env LIBGUESTFS_BACKEND=direct LIBGUESTFS_MEMSIZE=768 virt-customize --format raw -a "${VMDK_FILE}.raw" --run-command '
    CFG="/etc/cloud/cloud.cfg.d/99_vagrant.cfg"
    if [ -f "$CFG" ]; then
        sed -i "/network: {config: disabled}/d" "$CFG"
        echo "✅ Network config restriction successfully removed."
    else
        echo "⚠️  File $CFG not found. Skipping."
    fi
'
# Reclaim ownership before packing
sudo chown $(id -u):$(id -g) "${VMDK_FILE}.raw"

echo "🔄 Step 7: Re-packing RAW format back to VMware VMDK..."
qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse "${VMDK_FILE}.raw" "$VMDK_FILE"
rm -f "${VMDK_FILE}.raw"

echo "⚙️  Step 8: Converting to OVA (Hardware Version $HW_VERSION)..."
ovftool --maxVirtualHardwareVersion="$HW_VERSION" \
        --name="$CLEAN_NAME" \
        --annotation="AlmaLinux OS Enterprise Template" \
        "$VMX_FILE" "$OUTPUT_OVA"

echo "✅ Success! Enterprise template saved as: $OUTPUT_OVA"
EOF
chmod +x box2ova.sh
```

### What the Script Does

1. **Installs dependencies** — `libguestfs`, `qemu-img`, and `unzip` via `dnf`
2. **Auto-installs `ovftool`** — if not in `$PATH`, looks for a `.zip` in the current directory
3. **Extracts the `.box`** archive into a temporary directory
4. **Derives the OVA name** from the VMX `displayname`, stripping "Vagrant" suffixes
5. **Re-enables cloud-init networking** — removes `network: {config: disabled}` from `99_vagrant.cfg` inside the disk image (see [Cloud-init Note](#cloud-init-note) below)
6. **Converts to OVA** — using `ovftool` with the specified hardware version

### Cloud-init Note

AlmaLinux Vagrant boxes ship with `network: {config: disabled}` in `/etc/cloud/cloud.cfg.d/99_vagrant.cfg` to prevent cloud-init from managing network interfaces in Vagrant environments (VirtualBox, VMware Workstation, libvirt) where networking is handled by the hypervisor and Vagrant itself.

When deploying to **vSphere/ESXi**, cloud-init networking should be **re-enabled** so that the VM can obtain its network configuration from the vSphere datasource (via VMware Tools). The script handles this automatically by removing the `network: {config: disabled}` line from the disk image.

### Hardware Version

The script defaults to hardware version **20** (`vmx-20`), which corresponds to **ESXi 8.0 Update 1**. You can modify the `HW_VERSION` variable in the script if you need a different version:

| HW Version | ESXi Compatibility |
|:----------:|:-------------------|
| 19 | ESXi 7.0 U2+ |
| 20 | ESXi 8.0 U1+ |
| 21 | ESXi 8.0 U2+ |

## Step 4: Run the Script

Execute the script against the downloaded box file:

```bash
./box2ova.sh f5952274-22f3-11f1-9947-be8f8dec9788
```

or if you renamed the file:

```bash
./box2ova.sh AlmaLinux-9-Vagrant-vmware-9.6-20250522.0.x86_64.box
```

The script will extract the contents, adjust cloud-init settings, and output a ready-to-use `.ova` file in your current directory.

## Step 5: Deploy to vSphere/vCloud

Once the `.ova` is generated, deploy it to your cluster:

1. Log into your **vSphere Client** or **vCloud** Web GUI
2. Right-click your target Host or Cluster and select _Deploy OVF Template..._
3. Select **Local file**, upload your new `.ova`, and follow the prompts to configure networking and storage

## Support

- Broadcom OVF Tool: https://developer.broadcom.com/tools/open-virtualization-format-ovf-tool/latest
- AlmaLinux Cloud SIG Chat: https://chat.almalinux.org/almalinux/channels/sigcloud
- AlmaLinux Vagrant boxes: https://portal.cloud.hashicorp.com/vagrant/discover/almalinux
