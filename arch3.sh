#!/bin/bash

# === 配置参数 ===
ISO_PATH="/mnt/ntfs/iso/endeavouros.iso"     # ISO 文件在 NTFS 分区中的路径
ROOT_PARTITION="/dev/sda1"               # ext4 分区（安装 EndeavourOS）
NTFS_PARTITION="/dev/sda2"               # NTFS 分区（保留数据）
MOUNT_POINT="/mnt/target"                # 目标系统挂载点
TIMEZONE="Asia/Shanghai"                 # 时区
LOCALE="en_US.UTF-8"                     # 语言
KEYMAP="us"                              # 键盘布局
ISO_MOUNT="/mnt/iso"                     # ISO 挂载点
AIROOTFS_MOUNT="/mnt/airootfs"           # airootfs 挂载点

# === 步骤 1: 挂载 NTFS 分区 ===
echo "=== 挂载 NTFS 分区 ==="
ntfsfix "$NTFS_PARTITION"
mkdir -p /mnt/ntfs
mount -t ntfs-3g "$NTFS_PARTITION" /mnt/ntfs

# === 步骤 2: 挂载 ISO 文件 ===
echo "=== 挂载 ISO 文件 ==="
mkdir -p "$ISO_MOUNT"
mount -o loop "$ISO_PATH" "$ISO_MOUNT"

# === 步骤 3: 解压 airootfs.sfs ===
echo "=== 解压 airootfs.sfs ==="
mkdir -p "$AIROOTFS_MOUNT"
7z x "$ISO_MOUNT/airootfs.sfs" -o"$AIROOTFS_MOUNT" || {
    echo "Error: 7z 提取失败，尝试使用 squashfs-tools"
    mount -t squashfs "$ISO_MOUNT/airootfs.sfs" "$AIROOTFS_MOUNT" -o loop
}

# === 步骤 4: 从 airootfs 中提取工具 ===
echo "=== 提取工具 ==="
mkdir -p /tmp/tools
rsync -a "$AIROOTFS_MOUNT/usr/bin/rsync" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/grub-install" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/grub-mkconfig" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/chpasswd" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/systemctl" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/useradd" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/ln" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/locale-gen" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/mount" /tmp/tools/
rsync -a "$AIROOTFS_MOUNT/usr/bin/umount" /tmp/tools/

# 添加工具到 PATH
export PATH="/tmp/tools:$PATH"

# === 步骤 5: 格式化 ext4 分区 ===
echo "=== 格式化 ext4 分区 ==="
mkfs.ext4 "$ROOT_PARTITION" -L root

# === 步骤 6: 挂载目标分区 ===
echo "=== 挂载目标分区 ==="
mkdir -p "$MOUNT_POINT"
mount "$ROOT_PARTITION" "$MOUNT_POINT"

# === 步骤 7: 复制 airootfs 内容 ===
echo "=== 复制系统文件 ==="
rsync -a "$AIROOTFS_MOUNT/" "$MOUNT_POINT/"

# === 步骤 8: 挂载必要设备 ===
echo "=== 挂载必要设备 ==="
mkdir -p "$MOUNT_POINT/dev"
mkdir -p "$MOUNT_POINT/dev/pts"
mkdir -p "$MOUNT_POINT/proc"
mkdir -p "$MOUNT_POINT/sys"
mkdir -p "$MOUNT_POINT/run"
mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount --bind /proc "$MOUNT_POINT/proc"
mount --bind /sys "$MOUNT_POINT/sys"
mount --bind /run "$MOUNT_POINT/run"

# === 步骤 9: 进入 chroot 环境配置系统 ===
echo "=== 配置系统 ==="
chroot "$MOUNT_POINT" <<EOF

# 设置时区
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# 本地化设置
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# 主机名
echo "endeavouros" > /etc/hostname

# 键盘布局
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# 安装 GRUB
grub-install "$ROOT_PARTITION"
grub-mkconfig -o /boot/grub/grub.cfg

# 启用 NetworkManager
systemctl enable NetworkManager

# 设置 root 密码
echo 'root:ant2025root' | chpasswd

# 创建 ant 用户并设置密码
#useradd -m -g users -G wheel -s /bin/bash ant
#echo 'ant:ant2025root' | chpasswd

EOF

# === 步骤 10: 卸载所有挂载点 ===
echo "=== 卸载所有挂载点 ==="
umount "$MOUNT_POINT/dev/pts"
umount "$MOUNT_POINT/dev"
umount "$MOUNT_POINT/proc"
umount "$MOUNT_POINT/sys"
umount "$MOUNT_POINT/run"
umount "$MOUNT_POINT"

# === 步骤 11: 重启系统 ===
echo "=== 操作完成 ==="
reboot
