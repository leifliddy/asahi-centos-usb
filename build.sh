#!/bin/bash

# perhaps we should mandate the user specify the device
#usb_device='/dev/sda'
mkosi_rootfs='mkosi.rootfs'
mnt_usb='mnt_usb'

EFI_UUID='3051-D434'
BOOT_UUID='a1492762-3fe2-4908-a8b9-118439becd26'
ROOT_UUID='d747cb2a-aff1-4e47-8a33-c4d9b7475df9'

# uncomment to randomize the UUID's
#EFI_UUID=$(uuidgen | tr '[a-z]' '[A-Z]' | cut -c1-8 | fold -w4 | paste -sd '-')
#BOOT_UUID=$(uuidgen)
#ROOT_UUID=$(uuidgen)


if [ "$(whoami)" != 'root' ]; then
    echo "You must be root to run this script."
    exit 1
fi


# specify the usb device with the -d argument
while getopts d: arg
do
    case "${arg}" in
        d) usb_device=${OPTARG};;
    esac
done


mount_usb() {
    # mounts an existing usb drive to mnt_usb/ so you can inspect the contents or chroot into it...etc
    echo '### Mounting usb partitions...'
    systemctl daemon-reload
    # first try to mount the usb partitions via their uuid
    if [ $(blkid | egrep -i "$EFI_UUID|$BOOT_UUID|$ROOT_UUID" | wc -l) -eq 3 ]; then
        [[ -z "$(findmnt -n $mnt_usb)" ]] && mount -U $ROOT_UUID $mnt_usb
        [[ -z "$(findmnt -n $mnt_usb/boot)" ]] && mount -U $BOOT_UUID $mnt_usb/boot
        [[ -z "$(findmnt -n $mnt_usb/boot/efi)" ]] && mount -U $EFI_UUID $mnt_usb/boot/efi
    else
        # otherwise mount via the device id
        if [ -z $usb_device ]; then
            echo -e "\nthe usb device can't be mounted via the uuid values"
            echo -e "\ntherefore you must specify the usb device ie\n./build.sh -d /dev/sda mount\n"
            exit
        fi
        [[ -z "$(findmnt -n $mnt_usb)" ]] && mount "$usb_device"3 $mnt_usb
        [[ -z "$(findmnt -n $mnt_usb/boot)" ]] && mount "$usb_device"2 $mnt_usb/boot
        [[ -z "$(findmnt -n $mnt_usb/boot/efi)" ]] && mount "$usb_device"1 $mnt_usb/boot/efi
    fi
}

umount_usb() {
    # unmounts usb drive from mnt_usb/
    echo '### Unmounting usb partitions...'
    [[ "$(findmnt -n $mnt_usb/boot/efi)" ]] && umount $mnt_usb/boot/efi
    [[ "$(findmnt -n $mnt_usb/boot)" ]] && umount $mnt_usb/boot
    [[ "$(findmnt -n $mnt_usb)" ]] && umount $mnt_usb
}


# ./build.sh mount
#  or
# ./build.sh umount
#  to mount or unmount a usb drive (that was previously created by this script) to/from mnt_usb/
if [[ $1 == 'mount' ]]; then
    mount_usb
    exit
elif [[ $1 == 'umount' ]] || [[ $1 == 'unmount' ]]; then
    umount_usb
    exit
fi


[[ -z $usb_device ]] && echo -e "\nyou must specify a usb device ie\n./build.sh -d /dev/sda\n" && exit
[[ ! -e $usb_device ]] && echo -e "\n$usb_device doesn't exist\n" && exit

mkdir -p $mnt_usb $mkosi_rootfs


prepare_usb_device() {
    umount_usb
    echo '### Preparing USB device...'
    # create 5GB root partition
    #echo -e 'o\ny\nn\n\n\n+600M\nef00\nn\n\n\n+1G\n8300\nn\n\n\n+5G\n8300\nw\ny\n' | gdisk "$usb_device"
    # root parition will take up all remaining space
    echo -e 'o\ny\nn\n\n\n+600M\nef00\nn\n\n\n+1G\n8300\nn\n\n\n\n8300\nw\ny\n' | gdisk "$usb_device"
    mkfs.vfat -F 32 -n 'EFI-USB-FED' -i $(echo $EFI_UUID | tr -d '-') "$usb_device"1
    mkfs.ext4 -O '^metadata_csum' -U $BOOT_UUID -L 'fedora-usb-boot' -F "$usb_device"2 || mkfs.ext4 -O '^metadata_csum' -U $BOOT_UUID -L 'fedora-usb-boot' -F "$usb_device"p2
    mkfs.ext4 -O '^metadata_csum' -U $ROOT_UUID -L 'fedora-usb-root' -F "$usb_device"3 || mkfs.ext4 -O '^metadata_csum' -U $ROOT_UUID -L 'fedora-usb-root' -F "$usb_device"p3
    systemctl daemon-reload

    if [ $(blkid | egrep -i "$EFI_UUID|$BOOT_UUID|$ROOT_UUID" | wc -l) -ne 3 ]; then
        echo -e "\nthe partitions and/or filesystem were not created correctly on $usb_device\nexiting...\n"
        exit
    fi
}

mkosi_create_rootfs() {
    mkosi clean
    rm -rf .mkosi-*
    wget https://leifliddy.com/.vendorfw/all_firmware.tar.gz -O mkosi.skeleton/boot/efi/asahi/all_firmware.tar.gz
    wget https://leifliddy.com/.vendorfw/firmware.tar -O mkosi.skeleton/boot/efi/vendorfw/firmware.tar
    wget https://leifliddy.com/.vendorfw/manifest.txt -O mkosi.skeleton/boot/efi/vendorfw/manifest.txt
    mkosi
}

install_usb() {
    # if  $mnt_usb is mounted, then unmount it
    [[ "$(findmnt -n $mnt_usb/boot/efi)" ]] && umount $mnt_usb/boot/efi
    [[ "$(findmnt -n $mnt_usb/boot)" ]] && umount $mnt_usb/boot
    [[ "$(findmnt -n $mnt_usb)" ]] && umount $mnt_usb
    echo '### Cleaning up...'
    rm -f $mkosi_rootfs/var/cache/dnf/*
    echo '### Mounting usb partitions and copying files...'
    mount -U $ROOT_UUID $mnt_usb
    rsync -aHAX --delete --exclude '/tmp/*' --exclude '/boot/*' $mkosi_rootfs/ $mnt_usb
    mount -U $BOOT_UUID $mnt_usb/boot
    rsync -aHAX --delete $mkosi_rootfs/boot/ --exclude '/efi/*' $mnt_usb/boot
    mount -U $EFI_UUID $mnt_usb/boot/efi
    rsync -aHA --delete $mkosi_rootfs/boot/efi/ $mnt_usb/boot/efi
    echo '### Setting uuids for partitions in /etc/fstab...'
    sed -i "s/EFI_UUID_PLACEHOLDER/$EFI_UUID/" $mnt_usb/etc/fstab
    sed -i "s/BOOT_UUID_PLACEHOLDER/$BOOT_UUID/" $mnt_usb/etc/fstab
    sed -i "s/ROOT_UUID_PLACEHOLDER/$ROOT_UUID/" $mnt_usb/etc/fstab
    echo '### Running systemd-machine-id-setup...'
    # generate a machine-id
    chroot $mnt_usb systemd-machine-id-setup
    chroot $mnt_usb echo "KERNEL_INSTALL_MACHINE_ID=$(cat /etc/machine-id)" > /etc/machine-info
    echo '### Updating GRUB...'
    arch-chroot $mnt_usb /image.creation/update-grub
    echo "### Creating BLS (/boot/loader/entries/) entry..."
    chroot $mnt_usb /image.creation/create.bls.entry
    echo "### Enabling system services..."
    chroot $mnt_usb systemctl enable iwd.service sshd.service systemd-networkd.service
    echo "### Disabling systemd-firstboot..."
    chroot $mnt_usb rm -f /usr/lib/systemd/system/sysinit.target.wants/systemd-firstboot.service
    echo "### Restoring centos.repo..."
    chroot $mnt_usb mv /etc/yum.repos.d/centos.repo.rpmnew /etc/yum.repos.d/centos.repo
    echo "### Restoring epel.repo..."
    chroot $mnt_usb mv /etc/yum.repos.d/epel.repo.rpmnew /etc/yum.repos.d/epel.repo
    rm -f  $mnt_usb/etc/machine-id
    rm -rf $mnt_usb/image.creation
    # remove .gitignore file
    rm -f $mnt_usb/boot/efi/asahi/.gitignore
    rm -f $mnt_usb/boot/efi/vendorfw/.gitignore
    find $mnt_usb/boot/efi/ -type f | xargs chmod 700
    echo '### Unmounting usb partitions...'
    umount $mnt_usb/boot/efi
    umount $mnt_usb/boot
    umount $mnt_usb
    echo '### Done'
}

prepare_usb_device
mkosi_create_rootfs
install_usb
