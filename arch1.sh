#!/bin/bash

# === 配置参数 ===
ARCH_ROOT_PARTITION="/dev/sda1"  # Arch Linux安装的目标ext4分区
MOUNT_POINT="/mnt/arch"          # 挂载点目录
MIRROR="https://mirrors.tuna.tsinghua.edu.cn/archlinux/"  # 国内镜像源

# === 检查环境 ===
echo "=== 检查环境 ==="
if ! command -v curl &> /dev/null; then
    echo "安装curl工具..."
    apt update && apt install -y curl
fi

# === 分区准备 ===
echo "=== 分区准备 ==="
# 创建挂载点
mkdir -p $MOUNT_POINT

# 挂载ext4分区
echo "挂载Arch Linux根分区到 $MOUNT_POINT..."
mount $ARCH_ROOT_PARTITION $MOUNT_POINT
if [ $? -ne 0 ]; then
    echo "挂载失败，请检查分区设备名！"
    exit 1
fi

# 挂载必需的系统目录
for dir in dev proc sys run; do
    mount --bind /$dir $MOUNT_POINT/$dir
done

# === 安装基础系统 ===
echo "=== 安装基础系统 ==="
# 下载并安装Arch Linux基础系统
echo "下载Arch Linux基础系统..."
curl -O https://mirrors.tuna.tsinghua.edu.cn/archlinux/iso/latest/archlinux-bootstrap-$(date +%Y.%m).tar.gz
tar -xpf archlinux-bootstrap-*.tar.gz -C $MOUNT_POINT

# 复制国内镜像源配置
echo "配置国内镜像源..."
cat > $MOUNT_POINT/etc/pacman.d/mirrorlist <<EOF
Server = $MIRROR/\$repo/os/\$arch
EOF

# 进入新系统环境
echo "进入新系统环境..."
chroot $MOUNT_POINT /bin/bash <<EOF

# === 系统配置 ===
echo "=== 系统配置 ==="
# 设置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# 生成locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# 设置root密码和创建用户ant
echo "设置root密码并创建用户..."
passwd root <<EOF_PASS
ant2025root
ant2025root
EOF_PASS

useradd -m ant
passwd ant <<EOF_PASS
ant2025root
ant2025root
EOF_PASS

# 安装GRUB引导程序（假设使用BIOS模式）
pacman -Syu --noconfirm grub
grub-install --target=i386-pc /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

# 安装网络工具
pacman -Syu --noconfirm networkmanager
systemctl enable NetworkManager

# 安装显卡驱动（根据实际硬件选择）
pacman -Syu --noconfirm xf86-video-intel  # 示例：Intel集成显卡

# 清理
pacman -Sc --noconfirm

EOF

# === 退出并完成 ===
echo "=== 退出并完成 ==="
# 卸载所有挂载
umount -R $MOUNT_POINT

# 重启系统
echo "安装完成，正在重启..."
reboot
