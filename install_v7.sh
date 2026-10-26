#!/usr/bin/env bash

# Function to display loading animation
show_loading() {
    local pid=$!
    local delay=0.1
    local spinstr='|/-\'
    echo -n " "
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    echo " "
}

# Function to check for root access
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\e[31mThis script must be run as root\e[0m" # Red color
        exit 1
    fi
}

# Function to display system details
show_system_details() {
    echo -e "\e[34mGathering system details...\e[0m" # Blue color
    IP=$(curl -s http://checkip.amazonaws.com)
    RAM=$(free -m | awk '/Mem:/ { print $2 }')
    CPU=$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)
    STORAGE=$(df -h | awk '$NF=="/"{printf "%s", $2}')
    echo -e "\e[32mSystem Details:\nIP: $IP\nRAM: ${RAM}MB\nCPU: $CPU\nStorage: $STORAGE\e[0m" # Green color
}

# ASCII Banner - Ars CHR Installer
clear
echo -e "\e[1;36m==================================================================\e[0m"
echo -e "\e[1;32m     _          _      _____ _    _ _____    _____ _    _ _____  \e[0m"
echo -e "\e[1;32m    / \        | |    / ____| |  | |  __ \  / ____| |  | |  __ \ \e[0m"
echo -e "\e[1;32m   / _ \       | |   | |    | |__| | |__) || |    | |__| | |__) |\e[0m"
echo -e "\e[1;33m  / ___ \      | |   | |    |  __  |  _  / | |    |  __  |  _  / \e[0m"
echo -e "\e[1;33m /_/   \_\     |_|    \_____|_|  |_|_| \_\  \_____|_|  |_|_| \_\ \e[0m"
echo -e "\e[1;36m==================================================================\e[0m"
echo -e "\e[1;35m          >>> AUTOMATED MIKROTIK CHR NATIVE INSTALLER <<<        \e[0m"
echo -e "\e[1;35m          >>>              Created by Ars               <<<        \e[0m"
echo -e "\e[1;36m==================================================================\e[0m"
echo ""


# Check if the user is root
check_root

# Show system details
show_system_details

echo -e "\e[34mPreparation ...\e[0m" # Blue color
{
    apt install unzip -y > /dev/null 2>&1
} & show_loading

# Latest Stable
CHR_VERSION=7.25

# Environment
DISK=$(lsblk | grep "disk" | head -n 1 | cut -d' ' -f1)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
INTERFACE_IP=$(ip addr show $INTERFACE | grep global | cut -d' ' -f 6 | head -n 1)
INTERFACE_GATEWAY=$(ip route show | grep default | awk '{print $3}')

{
    wget -qO routeros.zip https://github.com/elseif/MikroTikPatch/releases/download/$CHR_VERSION/chr-$CHR_VERSION.img.zip && \
    unzip routeros.zip > /dev/null 2>&1 && \
    rm -rf routeros.zip
} & show_loading

echo -e "\e[33m[+] Mempersiapkan dan mengonfigurasi image CHR...\e[0m"

# 1. Pastikan folder mount ada
mkdir -p /mnt

# 2. Gunakan losetup dengan partscan agar partisi di dalam file .img langsung terbaca otomatis
LOOP_DEV=$(losetup --find --show --partscan chr-$CHR_VERSION.img)

# 3. Mount partisi pertama dari loop device tersebut (biasanya p1)
if mount "${LOOP_DEV}p1" /mnt; then
    echo -e "\e[32m[+] Berhasil mount partisi CHR via ${LOOP_DEV}p1\e[0m"
else
    # Fallback jika penamaan partisi berbeda
    mount "${LOOP_DEV}" /mnt || {
        echo -e "\e[31m[!] Error: Gagal total melakukan mount partisi image CHR.\e[0m"
        losetup -d "$LOOP_DEV"
        exit 1
    }
fi

# 4. Pastikan folder rw ada di dalam image, lalu buat file autorun.scr
mkdir -p /mnt/rw
cat <<EOF > /mnt/rw/autorun.scr
/ip address add address=${INTERFACE_IP} interface=[/interface ethernet find where name=ether1]
/ip route add gateway=${INTERFACE_GATEWAY}
EOF

# 5. Sync, unmount, dan bersihkan losetup
sync
umount /mnt
losetup -d "$LOOP_DEV"

echo -e "\e[32m[+] Konfigurasi autorun berhasil disisipkan!\e[0m"

# 6. Proses tulis ke disk VPS (dd)
{
    echo u > /proc/sysrq-trigger
    dd if=chr-$CHR_VERSION.img of=/dev/${DISK} bs=4M status=progress conv=fsync
} & show_loading

echo -e "\e[32mInstallation complete. Reboot your server now, Please log in and configure your password using Winbox.\e[0m" # Green color