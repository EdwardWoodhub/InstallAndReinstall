#!/bin/bash

# === 配置参数 ===
ARCH_MIRROR="https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch"
ROOT_PARTITION="/dev/sda1"         # ext4 分区
BOOT_PARTITION="/dev/sda1"         # 与根分区相同（UEFI 系统）
SWAP_PARTITION=""                   # 可选，若需要交换分区
NTFS_PARTITION="/dev/sda2"         # 保留 NTFS 分区
MOUNT_POINT="/mnt"                 # 挂载点
TIMEZONE="Asia/Shanghai"           # 时区
LOCALE="en_US.UTF-8"               # 语言
KEYMAP="us"                        # 键盘布局

# === 步骤 1: 检查分区 ===
echo "=== 检查分区 ==="
lsblk
read -p "确认分区是否正确（ext4: $ROOT_PARTITION, NTFS: $NTFS_PARTITION）？[y/N] " confirm
if [[ "$confirm" != "y" ]]; then
    echo "操作已取消。"
    exit 1
fi

# === 步骤 2: 格式化 ext4 分区 ===
echo "=== 格式化 ext4 分区 ==="
mkfs.ext4 "$ROOT_PARTITION" -L root

# === 步骤 3: 挂载分区 ===
echo "=== 挂载分区 ==="
mount "$ROOT_PARTITION" "$MOUNT_POINT"
mkdir -p "$MOUNT_POINT/boot"
mount --mkdir "$BOOT_PARTITION" "$MOUNT_POINT/boot"

# 如果需要交换分区
if [[ -n "$SWAP_PARTITION" ]]; then
    mkswap "$SWAP_PARTITION"
    swapon "$SWAP_PARTITION"
fi

# === 步骤 4: 更新镜像源 ===
echo "=== 更新镜像源 ==="
sed -i "1s/.*/Server = $ARCH_MIRROR/" /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm

# === 步骤 5: 安装基础系统 ===
echo "=== 安装基础系统 ==="
pacstrap "$MOUNT_POINT" base base-devel linux linux-firmware networkmanager ntfs-3g

# === 步骤 6: 生成 fstab ===
echo "=== 生成 fstab ==="
genfstab -U "$MOUNT_POINT" >>"$MOUNT_POINT/etc/fstab"

# === 步骤 7: 进入新系统环境 ===
echo "=== 配置系统 ==="
arch-chroot "$MOUNT_POINT" <<EOF

# 设置时区
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# 本地化设置
echo "$LOCALE UTF-8" >>/etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# 主机名
echo "arch" > /etc/hostname

# 键盘布局
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# 设置 root 密码
echo 'ant2025root' | passwd --stdin root

# 创建 ant 用户
useradd -m -g users -G wheel -s /bin/bash ant
echo 'ant2025root' | passwd --stdin ant

# 安装 GRUB 引导
pacman -S --noconfirm grub
grub-install "$ROOT_PARTITION"
grub-mkconfig -o /boot/grub/grub.cfg

# 启用 NetworkManager
systemctl enable NetworkManager

EOF

# === 步骤 8: 退出并重启 ===
echo "=== 操作完成 ==="
umount -R "$MOUNT_POINT"
reboot
