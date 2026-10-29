
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# MikroTik CHR v7 Native Installer
# Official MikroTik image / Rescue Mode only
# ============================================================

CHR_VERSION="${CHR_VERSION:-7.25}"
WORKDIR="${WORKDIR:-/tmp/chr-installer}"
IMAGE_URL="https://github.com/elseif/MikroTikPatch/releases/download/${CHR_VERSION}/chr-${CHR_VERSION}-legacy-bios.img.zip"

DISK="${DISK:-}"
LOOPDEV=""
MOUNTED=""
INSTALL_STARTED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

cleanup() {
    local rc=$?

    trap - EXIT

    if [[ -n "$MOUNTED" ]]; then
        umount "$MOUNTED" || true
    fi

    if [[ -n "$LOOPDEV" ]]; then
        losetup -d "$LOOPDEV" || true
    fi

    if (( rc != 0 )); then
        warn "Installation stopped (exit code: $rc)."

        if (( INSTALL_STARTED )); then
            warn "Disk writing was interrupted."
            warn "The previous OS may no longer be bootable."
        fi
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_root() {
    [[ "$EUID" -eq 0 ]] || die "Run as root."
}

check_environment() {
    log "Checking environment..."

    [[ "$(uname -m)" == "x86_64" ]] ||
        die "This installer requires x86_64."

    [[ -d /sys/block ]] ||
        die "Block device information unavailable."

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT=$(systemd-detect-virt || true)

        if [[ "$VIRT" == "lxc" || "$VIRT" == "docker" ||
              "$VIRT" == "openvz" ]]; then
            die "Native CHR installation is not supported in containers."
        fi
    fi

    success "Environment checked."
}

install_dependencies() {
    log "Checking dependencies..."

    local packages=()

    command -v curl >/dev/null || packages+=(curl)
    command -v unzip >/dev/null || packages+=(unzip)
    command -v lsblk >/dev/null || packages+=(util-linux)
    command -v losetup >/dev/null || packages+=(util-linux)
    command -v blkid >/dev/null || packages+=(util-linux)
    command -v findmnt >/dev/null || packages+=(util-linux)
    command -v blockdev >/dev/null || packages+=(util-linux)
    command -v python3 >/dev/null || packages+=(python3)

    if (( ${#packages[@]} > 0 )); then
        command -v apt-get >/dev/null ||
            die "Missing dependencies; apt-get unavailable."

        apt-get update
        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${packages[@]}"
    fi

    success "Dependencies ready."
}

show_system() {
    echo
    echo "=================================================="
    echo "       MikroTik CHR v7 Native Installer"
    echo "=================================================="

    echo "CHR Version : $CHR_VERSION"
    echo "Architecture: $(uname -m)"
    echo "CPU         : $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo)"
    echo "RAM         : $(free -h | awk '/Mem:/{print $2}')"

    echo
    echo "Available disks:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL

    echo
    echo "Current network:"
    ip -4 -brief address show
    ip -4 route show default || true

    echo "=================================================="
}



detect_disk() {
    echo

    if [[ -z "$DISK" ]]; then
        read -r -p "Target disk (example /dev/sda): " DISK
    fi

    [[ -b "$DISK" ]] ||
        die "Invalid block device: $DISK"

    DISK=$(readlink -f "$DISK")

    [[ "$(lsblk -dn -o TYPE "$DISK")" == "disk" ]] ||
        die "Target must be a whole disk, not a partition."

    case "$DISK" in
        /dev/loop*|/dev/ram*|/dev/zram*|/dev/dm-*)
            die "Unsupported target disk."
            ;;
    esac

    log "Checking target disk usage..."

    local device
    local children
    local mounted
    local root_source
    local root_backing

    children=$(lsblk -nrpo NAME "$DISK")

    # Check active root filesystem and its backing devices.
    root_source=$(findmnt -n -o SOURCE / || true)

    root_backing=$(lsblk -spno NAME "$root_source" 2>/dev/null || true)

    if grep -Fxq "$DISK" <<< "$root_backing"; then
        die "Target disk contains the running OS. Use Rescue Mode."
    fi

    # Check all mounted partitions.
    while IFS= read -r device; do
        mounted=$(findmnt -rn -S "$device" -o TARGET || true)

        if [[ -n "$mounted" ]]; then
            die "$device is mounted at $mounted. Use Rescue Mode."
        fi

        if lsblk -nr -o MOUNTPOINT "$device" |
            grep -q '[^[:space:]]'; then
            die "$device contains an active mount."
        fi

        if swapon --noheadings --raw --output NAME 2>/dev/null |
            grep -Fxq "$device"; then
            die "$device is used as swap."
        fi

        local base
        base=$(basename "$device")

        if [[ -d "/sys/class/block/$base/holders" ]] &&
           [[ -n "$(ls -A "/sys/class/block/$base/holders")" ]]; then
            die "$device has active block-device holders."
        fi

    done <<< "$children"

    success "Target disk validated: $DISK"
}



get_network() {
    log "Detecting network configuration..."

    INTERFACE=$(ip -4 route show default |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

    GATEWAY=$(ip -4 route show default |
        awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')

    IP_CIDR=""

    if [[ -n "$INTERFACE" ]]; then
        IP_CIDR=$(ip -o -4 addr show dev "$INTERFACE" scope global |
            awk 'NR==1 {print $4}')
    fi

    echo
    echo "Interface : ${INTERFACE:-unknown}"
    echo "IP/CIDR   : ${IP_CIDR:-unknown}"
    echo "Gateway   : ${GATEWAY:-unknown}"

    echo
    warn "The Linux interface name may differ from RouterOS."
    warn "Automatic network configuration assumes CHR ether1."
}

download_image() {
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"

    log "Downloading official MikroTik CHR..."

    curl -fL \
        --retry 3 \
        --connect-timeout 20 \
        --output chr.zip \
        "$IMAGE_URL" ||
        die "Image download failed: $IMAGE_URL"

    [[ -s chr.zip ]] || die "Downloaded archive is empty."

    unzip -t chr.zip >/dev/null ||
        die "Downloaded ZIP is invalid."

    unzip -o -j chr.zip "chr-${CHR_VERSION}.img" -d "$WORKDIR" ||
        die "Image extraction failed."

    IMAGE="$WORKDIR/chr-${CHR_VERSION}.img"

    [[ -s "$IMAGE" ]] || die "CHR image missing."

    success "Image downloaded and extracted."

    sha256sum "$IMAGE"
    warn "Compare this hash with a trusted vendor checksum if available."
}

validate_image() {
    log "Validating disk image..."

    local image_size disk_size

    image_size=$(stat -c%s "$IMAGE")
    disk_size=$(blockdev --getsize64 "$DISK")

    (( image_size > 10485760 )) ||
        die "Image unexpectedly small."

    (( disk_size > image_size )) ||
        die "Target disk is smaller than image."

    if ! fdisk -l "$IMAGE" >/dev/null 2>&1; then
        die "Invalid or unsupported image partition table."
    fi

    success "Image partition table validated."
}

prepare_autorun() {
    echo
    read -r -p "Attempt offline static-IP autorun? [y/N]: " ANSWER

    [[ "$ANSWER" =~ ^[Yy]$ ]] || {
        warn "Skipping autorun. Configure network via VPS console."
        return 0
    }

    [[ -n "$IP_CIDR" && -n "$GATEWAY" ]] ||
        die "IP or gateway unavailable. Cannot create autorun."

    log "Inspecting CHR partitions..."

    LOOPDEV=$(losetup --find --show --partscan --read-only "$IMAGE") ||
        die "Unable to attach image."

    udevadm settle 2>/dev/null || sleep 2

    local part label fstype
    local rw_part=""

    while IFS= read -r part; do
        [[ "$part" == "$LOOPDEV" ]] && continue

        label=$(blkid -s LABEL -o value "$part" 2>/dev/null || true)
        fstype=$(blkid -s TYPE -o value "$part" 2>/dev/null || true)

        if [[ "$label" == "rw" && "$fstype" == "ext4" ]]; then
            rw_part="$part"
            break
        fi
    done < <(lsblk -nrpo NAME "$LOOPDEV")

    if [[ -z "$rw_part" ]]; then
        warn "No compatible rw partition detected."
        warn "Autorun will be skipped. Use console configuration."
        losetup -d "$LOOPDEV"
        LOOPDEV=""
        return 0
    fi

    # Release the read-only mapping before requesting write access.
    losetup -d "$LOOPDEV"
    LOOPDEV=""

    LOOPDEV=$(losetup --find --show --partscan "$IMAGE") ||
        die "Unable to attach writable image."

    udevadm settle 2>/dev/null || sleep 2

    local partnum
    partnum="${rw_part##*p}"

    # Resolve partition by its partition number, not by assuming
    # the loop device number remains unchanged.
    local target_part=""
    while IFS= read -r part; do
        [[ "$part" == "$LOOPDEV" ]] && continue
        if [[ "$(lsblk -dn -o PARTN "$part")" == "$partnum" ]]; then
            target_part="$part"
            break
        fi
    done < <(lsblk -nrpo NAME "$LOOPDEV")

    [[ -n "$target_part" ]] ||
        die "Could not resolve writable rw partition."

    mkdir -p "$WORKDIR/mount"
    MOUNTED="$WORKDIR/mount"

    mount -t ext4 "$target_part" "$MOUNTED" ||
        die "Unable to mount rw partition."

    # Do not overwrite an existing autorun.
    [[ ! -e "$MOUNTED/autorun.scr" ]] ||
        die "An autorun.scr already exists."

    cat > "$MOUNTED/autorun.scr" <<EOF
:delay 10s
/ip address add address=$IP_CIDR interface=ether1
/ip route add dst-address=0.0.0.0/0 gateway=$GATEWAY
EOF

    sync

    [[ -s "$MOUNTED/autorun.scr" ]] ||
        die "Failed to create autorun.scr."

    umount "$MOUNTED"
    MOUNTED=""

    losetup -d "$LOOPDEV"
    LOOPDEV=""

    success "Autorun written to image."
    warn "Autorun execution is image-dependent; console access remains essential."
}

confirm_installation() {
    echo
    echo -e "${RED}=================================================="
    echo "               DESTRUCTIVE OPERATION"
    echo "==================================================${NC}"

    echo "Target : $DISK"
    echo "Image  : $IMAGE"
    echo
    echo "ALL DATA ON THIS DISK WILL BE DESTROYED."
    echo "The current Linux installation will be replaced."
    echo

    read -r -p "Type ERASE to continue: " CONFIRM

    [[ "$CONFIRM" == "ERASE" ]] ||
        die "Installation cancelled."
}

write_image() {
    log "Writing CHR image to $DISK..."

    INSTALL_STARTED=1

    dd if="$IMAGE" \
       of="$DISK" \
       bs=4M \
       iflag=fullblock \
       oflag=direct \
       conv=fsync \
       status=progress ||
        die "Disk writing failed."

    sync

    log "Verifying written image..."

    local size
    size=$(stat -c%s "$IMAGE")

    if ! cmp -n "$size" "$IMAGE" "$DISK"; then
        die "Image verification failed."
    fi

    INSTALL_STARTED=0

    success "CHR image written and verified."
}

finish() {
    echo
    echo "=================================================="
    echo -e "${GREEN}       INSTALLATION COMPLETED${NC}"
    echo "=================================================="
    echo
    echo "Target disk : $DISK"
    echo "CHR version : $CHR_VERSION"
    echo
    warn "Set the VPS boot disk to $DISK."
    warn "Remove rescue ISO before rebooting."
    warn "Keep the provider console/VNC available."
    echo
    echo "Reboot from your VPS provider panel."
    echo "Configure RouterOS and change the admin password."
    echo
}

main() {
    check_root
    check_environment
    install_dependencies
    show_system
    detect_disk
    get_network
    download_image
    validate_image
    prepare_autorun
    confirm_installation
    write_image
    finish
}

main "$@"
