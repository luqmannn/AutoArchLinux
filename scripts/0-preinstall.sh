#!/usr/bin/env bash
#-------------------------------------------------------------------------
#    _         _          _             _     _     _
#   / \  _   _| |_ ___   / \   _ __ ___| |__ | |   (_)_ __  _   ___  __
#  / _ \| | | | __/ _ \ / _ \ | '__/ __| '_ \| |   | | '_ \| | | \ \/ /
# / ___ \ |_| | || (_) / ___ \| | | (__| | | | |___| | | | | |_| |>  <
#/_/   \_\__,_|\__\___/_/   \_\_|  \___|_| |_|_____|_|_| |_|\__,_/_/\_\
#-------------------------------------------------------------------------
#
#
# Preinstall
# Contains the steps necessary to configure and pacstrap the install to selected drive. 
echo -ne "
-------------------------------------------------------------------------
    _         _          _             _     _     _
   / \  _   _| |_ ___   / \   _ __ ___| |__ | |   (_)_ __  _   ___  __
  / _ \| | | | __/ _ \ / _ \ | '__/ __| '_ \| |   | | '_ \| | | \ \/ /
 / ___ \ |_| | || (_) / ___ \| | | (__| | | | |___| | | | | |_| |>  <
/_/   \_\__,_|\__\___/_/   \_\_|  \___|_| |_|_____|_|_| |_|\__,_/_/\_\
-------------------------------------------------------------------------
                    Auto Arch Linux Install
-------------------------------------------------------------------------

Setting up mirrors for optimal download
"
source $CONFIGS_DIR/setup.conf
iso=$(curl -4 ifconfig.co/country-iso)
timedatectl set-ntp true
pacman -S --noconfirm archlinux-keyring #update keyrings to latest to prevent packages failing to install
pacman -S --noconfirm --needed pacman-contrib terminus-font
setfont ter-v22b
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
pacman -S --noconfirm --needed reflector rsync grub
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
echo -ne "
-----------------------------------------------------------------------
                Setting up ISO mirrors for faster downloads
-----------------------------------------------------------------------
"
reflector -a 48 -c $iso -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
mkdir /mnt &>/dev/null # Hiding error message if any
echo -ne "
-----------------------------------------------------------------------
                Installing Pre-requisites
-----------------------------------------------------------------------
"
pacman -S --noconfirm --needed gptfdisk btrfs-progs glibc
echo -ne "
-----------------------------------------------------------------------
                    Format The Disk
-----------------------------------------------------------------------
"
umount -A --recursive /mnt # Make sure everything is unmounted before we start
# Disk preparation
sgdisk -Z ${DISK} # Zap all on disk
sgdisk -a 2048 -o ${DISK} # New GPT disk 2048 alignment

# Create partitions
sgdisk -n 1::+1M --typecode=1:ef02 --change-name=1:'BIOSBOOT' ${DISK} # Partition 1 (BIOS Boot Partition)
sgdisk -n 2::+300M --typecode=2:ef00 --change-name=2:'EFIBOOT' ${DISK} # Partition 2 (UEFI Boot Partition)
sgdisk -n 3::-0 --typecode=3:8300 --change-name=3:'ROOT' ${DISK} # Partition 3 (Root), default start, remaining
if [[ ! -d "/sys/firmware/efi" ]]; then # Checking for BIOS system
    sgdisk -A 1:set:2 ${DISK}
fi
partprobe ${DISK} # Reread partition table to ensure it is correct

# Create filesystems
echo -ne "
-----------------------------------------------------------------------
                    Creating Filesystems
-----------------------------------------------------------------------
"
# Creates the BTRFS subvolumes. 
createsubvolumes () {
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var
    btrfs subvolume create /mnt/@tmp
    btrfs subvolume create /mnt/@.snapshots
}

# Mount all BTRFS subvolumes after root has been mounted.
mountallsubvol () {
    mount -o ${MOUNT_OPTIONS},subvol=@home ${partition3} /mnt/home
    mount -o ${MOUNT_OPTIONS},subvol=@tmp ${partition3} /mnt/tmp
    mount -o ${MOUNT_OPTIONS},subvol=@var ${partition3} /mnt/var
    mount -o ${MOUNT_OPTIONS},subvol=@.snapshots ${partition3} /mnt/.snapshots
}

# BTRFS subvolulme creation and mounting. 
subvolumesetup () {
# Create nonroot subvolumes
    createsubvolumes     
# Unmount root to remount with subvolume 
    umount /mnt
# Mount @ subvolume
    mount -o ${MOUNT_OPTIONS},subvol=@ ${partition3} /mnt
# Make directories home, .snapshots, var, tmp
    mkdir -p /mnt/{home,var,tmp,.snapshots}
# Mount subvolumes
    mountallsubvol
}

if [[ "${DISK}" =~ "nvme" ]]; then
    partition2=${DISK}p2
    partition3=${DISK}p3
else
    partition2=${DISK}2
    partition3=${DISK}3
fi

if [[ "${FS}" == "btrfs" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
    mkfs.btrfs -L ROOT ${partition3} -f
    mount -t btrfs ${partition3} /mnt
    subvolumesetup
elif [[ "${FS}" == "ext4" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
    mkfs.ext4 -L ROOT ${partition3}
    mount -t ext4 ${partition3} /mnt
elif [[ "${FS}" == "luks" ]]; then
    mkfs.vfat -F32 -n "EFIBOOT" ${partition2}
# Enter LUKS password to cryptsetup and format root partition
    echo -n "${LUKS_PASSWORD}" | cryptsetup -y -v luksFormat ${partition3} -
# Open LUKS container and ROOT will be place holder 
    echo -n "${LUKS_PASSWORD}" | cryptsetup open ${partition3} ROOT -
# Now format that container
    mkfs.btrfs -L ROOT ${partition3}
# Create subvolumes for BTRFS
    mount -t btrfs ${partition3} /mnt
    subvolumesetup
# Store UUID of encrypted partition for GRUB
    echo ENCRYPTED_PARTITION_UUID=$(blkid -s UUID -o value ${partition3}) >> $CONFIGS_DIR/setup.conf
fi

# mount target
mkdir -p /mnt/boot/efi
mount -t vfat -L EFIBOOT /mnt/boot/

if ! grep -qs '/mnt' /proc/mounts; then
    echo "Drive is not mounted can not continue"
    echo "Rebooting in 3 Seconds ..." && sleep 1
    echo "Rebooting in 2 Seconds ..." && sleep 1
    echo "Rebooting in 1 Second ..." && sleep 1
    reboot now
fi
echo -ne "
-----------------------------------------------------------------------
                 Install Arch Linux on Main Drive
-----------------------------------------------------------------------
"
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo archlinux-keyring wget libnewt --noconfirm --needed
echo "keyserver hkp://keyserver.ubuntu.com" >> /mnt/etc/pacman.d/gnupg/gpg.conf
cp -R ${SCRIPT_DIR} /mnt/root/ArchTitus
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

genfstab -L /mnt >> /mnt/etc/fstab
echo " 
  Generated /etc/fstab:
"
cat /mnt/etc/fstab
echo -ne "
-----------------------------------------------------------------------
                 Install & Check GRUB BIOS Bootloader
-----------------------------------------------------------------------
"
if [[ ! -d "/sys/firmware/efi" ]]; then
    grub-install --boot-directory=/mnt/boot ${DISK}
else
    pacstrap /mnt efibootmgr --noconfirm --needed
fi
echo -ne "
-----------------------------------------------------------------------
                 Check For Low Memory Systems <8G
-----------------------------------------------------------------------
"
TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')
if [[  $TOTAL_MEM -lt 8000000 ]]; then
    # Put swap into the actual system, not into RAM disk, otherwise there is no point in it, it'll cache RAM into RAM. So, /mnt/ everything.
    mkdir -p /mnt/opt/swap # make a dir that we can apply NOCOW to to make it btrfs-friendly.
    chattr +C /mnt/opt/swap # apply NOCOW, for BTRFS only
    dd if=/dev/zero of=/mnt/opt/swap/swapfile bs=1M count=2048 status=progress
    chmod 600 /mnt/opt/swap/swapfile # set permissions.
    chown root /mnt/opt/swap/swapfile
    mkswap /mnt/opt/swap/swapfile
    swapon /mnt/opt/swap/swapfile
    # The line below is written to /mnt/ but doesn't contain /mnt/, since it's just / for the system itself.
    echo "/opt/swap/swapfile	none	swap	sw	0	0" >> /mnt/etc/fstab # Add swap to fstab, so it KEEPS working after installation.
fi
echo -ne "
-----------------------------------------------------------------------
                 System Ready For The First Setup Process
-----------------------------------------------------------------------
"
