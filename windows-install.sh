#!/bin/bash

echo "*** Update and Upgrade ***"
apt update -y && apt upgrade -y
echo "Update and Upgrade finish ***"

echo "*** Install linux-image-amd64 ***"
sudo apt install linux-image-amd64
echo "Install linux-image-amd64 finish ***"

echo "*** Reinstall initramfs-tools ***"
sudo apt install --reinstall initramfs-tools
echo "Reinstall initramfs-tools finish ***"

echo "*** Install grub2, wimtools, ntfs-3g ***"
apt install grub2 wimtools ntfs-3g -y
echo "Install grub2, wimtools, ntfs-3g finish ***"

echo "*** Get the disk size in GB and convert to MB ***"
disk_size_gb=$(parted /dev/sda --script print | awk '/^Disk \/dev\/sda:/ {print int($3)}')
disk_size_mb=$((disk_size_gb * 1024))
echo "Get the disk size in GB and convert to MB finish ***"

echo "*** Calculate partition size (50% of total size) ***"
part_size_mb=$((disk_size_mb / 2))
echo "Calculate partition size (50% of total size) finish ***"

echo "*** Create GPT partition table ***"
parted /dev/sda --script -- mklabel gpt
echo "Create GPT partition table finish ***"

echo "*** Create two partitions ***"
parted /dev/sda --script -- mkpart primary ntfs 1MB ${part_size_mb}MB
echo "Create first partitions"
parted /dev/sda --script -- mkpart primary ntfs ${part_size_mb}MB 100%
echo "Create second partitions"
echo "Create two partitions finish ***"

echo "*** Inform kernel of partition table changes ***"
partprobe /dev/sda
sleep 60

partprobe /dev/sda
sleep 60

partprobe /dev/sda
sleep 60
echo "Inform kernel of partition table changes"

# echo "*** Verify partitions ***"
# fdisk -l /dev/sda
# echo "Verify partitions finish ***"

# Check if partitions are created and formatted successfully
echo "*** Check if partitions are created and formatted successfully ***"
if lsblk /dev/sda1 && lsblk /dev/sda2; then
    echo "Check if partitions are created and formatted successfully finish ***"
else
    echo "Error: Partitions were not created or formatted successfully"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

echo "*** Format the partitions ***"
mkfs.ntfs -f /dev/sda1
echo "Format the partitions sda1"
mkfs.ntfs -f /dev/sda2
echo "Format the partitions sda1"
echo "Format the partitions finish ***"

echo "NTFS partitions created"

echo "*** Install gdisk ***"
sudo apt-get install gdisk
echo "Install gdisk finish ***"

echo "*** Run gdisk commands ***"
echo -e "r\ng\np\nw\nY\n" | gdisk /dev/sda
echo "Run gdisk commands finish ***"

echo "*** Mount /dev/sda1 to /mnt ***"
mount /dev/sda1 /mnt
echo "Mount /dev/sda1 to /mnt finish ***"

echo "*** Prepare directory for the Windows disk ***"
cd ~
mkdir -p windisk
echo "Prepare directory for the Windows disk finish ***"

echo "*** Mount /dev/sda2 to windisk ***"
mount /dev/sda2 windisk
echo "Mount /dev/sda2 to windisk finish ***"

echo "*** Install GRUB ***"
grub-install --root-directory=/mnt /dev/sda
echo "Install GRUB finish ***"

echo "*** Edit GRUB configuration ***"
cd /mnt/boot/grub
cat <<EOF > grub.cfg
menuentry "windows installer" {
	insmod ntfs
	search --no-floppy --set=root --file=/bootmgr
	ntldr /bootmgr
	boot
}
EOF
echo "Edit GRUB configuration finish ***"

echo "*** Prepare winfile directory ***"
cd /root/windisk
mkdir -p winfile
echo "Prepare winfile directory finish ***"

# Ask if the user wants to download Windows.iso
read -p "Do you want to download Windows.iso? (Y/N): " download_choice

if [[ "$download_choice" == "Y" || "$download_choice" == "y" ]]; then
    # Ask for the URL to download Windows.iso
    read -p "Enter the URL for Windows.iso (leave blank to use default): " windows_url
    if [ -z "$windows_url" ]; then
        windows_url="https://bit.ly/3UGzNcB"  # Replace with the actual default URL
    fi
    
    wget -O Windows.iso --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" "$windows_url"
    echo "Download completed"
else
    echo "Please upload the Windows operating system image in 'root/windisk' folder and rename as 'Windows.iso'."
    read -p "Press any key to continue once you have uploaded the image..." -n1 -s
fi

# Check if the ISO was downloaded successfully
echo "*** Check if the ISO of windows ***"
if [ -f "Windows.iso" ]; then
    mount -o loop Windows.iso winfile
    rsync -avz --progress winfile/* /mnt
    umount winfile
    echo "Check if the ISO of windows finish ***"
else
    echo "Failed to download Windows.iso"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

# Ask if the user wants to download the ISO image of Virtio drivers
read -p "Do you want to download the ISO image of Virtio drivers? (Y/N): " download_choice

if [[ "$download_choice" == "Y" || "$download_choice" == "y" ]]; then
    # Ask for the URL to download Virtio.iso
    read -p "Enter the URL for Virtio.iso (leave blank to use default): " virtio_url
    if [ -z "$virtio_url" ]; then
        virtio_url="https://bit.ly/4d1g7Ht"  # Replace with the actual default URL
    fi
    
    wget -O Virtio.iso --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" "$virtio_url"
    echo "Download completed"
else
    echo "Please upload the Windows operating system image in the 'root/windisk' folder and rename it as 'Virtio.iso'."
    read -p "Press any key to continue once you have uploaded the image..." -n1 -s
fi

# Check if the ISO was downloaded successfully
echo "*** Check if the ISO of drivers ***"
if [ -f "Virtio.iso" ]; then
    mount -o loop Virtio.iso winfile
    mkdir -p /mnt/sources/virtio
    rsync -avz --progress winfile/* /mnt/sources/virtio
    umount winfile
    echo "Check if the ISO of drivers finish ***"
else
    echo "Failed to download Virtio.iso"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

cd /mnt/sources

touch cmd.txt

echo 'add virtio /virtio_drivers' >> cmd.txt

# List images in boot.wim
echo "*** List images in boot.wim ***"
wimlib-imagex info boot.wim

# Prompt user to enter a valid image index
echo "Please enter a valid image index from the list above:"
read image_index
echo "List images in boot.wim finish ***"

# Check if boot.wim exists before updating
echo "*** Rebooting the system... ***"
if [ -f boot.wim ]; then
    wimlib-imagex update boot.wim $image_index < cmd.txt
    echo "Install linux-image-amd64 finish ***"
else
    echo "boot.wim not found"
    read -p "Press any key to exit..." -n1 -s
    exit 1
fi

# Ask if the user wants to reboot
read -p "Do you want to reboot the system now? (Y/N): " reboot_choice

if [[ "$reboot_choice" == "Y" || "$reboot_choice" == "y" ]]; then
    sudo reboot
else
    echo "Continuing without rebooting"
fi