#!/bin/bash
set -eo pipefail

# ======================
# 配置参数（安装前必须修改）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区（EXT4）
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（NTFS存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/manjaro.iso"
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境（强化NTFS清理）
# ======================
cleanup() {
  echo -e "\n===== 执行清理操作 ====="
  
  # 卸载顺序：从深层到浅层
  local unmount_order=(
    "${MOUNT_DIR}/dev"
    "${MOUNT_DIR}/proc"
    "${MOUNT_DIR}/sys"
    "/mnt/squashfs"
    "/mnt/iso"
    "${MOUNT_DIR}"
    "/root/ntfs"
  )

  # 卸载所有挂载点
  for mnt in "${unmount_order[@]}"; do
    if mountpoint -q "${mnt}"; then
      echo "[清理] 卸载 ${mnt}"
      umount -l "${mnt}" 2>/dev/null || true
      sleep 0.3  # 防止设备忙
    fi
  done

  # 删除残留目录
  rm -rf "/mnt/iso" "/mnt/squashfs" 2>/dev/null || true
  [ -d "/root/ntfs" ] && rmdir "/root/ntfs" 2>/dev/null || true
}
trap cleanup EXIT

# ======================
# 安装依赖（确保NTFS支持）
# ======================
install_deps() {
  echo "===== 安装系统依赖 ====="
  
  # Debian系统配置
  if grep -qi "debian" /etc/os-release; then
    echo "[系统] 配置Debian软件源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    apt-get update -qq
  fi

  # 安装核心组件
  apt-get install -y --no-install-recommends \
    ntfs-3g \
    wget \
    binwalk \
    libarchive-tools \
    grub-common || {
    echo "[-] 软件包安装失败"
    exit 1
  }
}

# ======================
# NTFS分区处理（增强版）
# ======================
mount_ntfs() {
  echo "===== 处理NTFS分区 ====="
  mkdir -p "/root/ntfs"

  # 检查现有挂载
  if mount | grep -q "${NTFS_PARTITION}"; then
    echo "[NTFS] 分区已挂载，跳过初始化"
    return 0
  fi

  # 分区修复
  echo "[NTFS] 检查文件系统"
  if ! ntfsfix --force "${NTFS_PARTITION}"; then
    echo "[!] 自动修复失败，尝试卸载后修复"
    umount -l "${NTFS_PARTITION}" 2>/dev/null || true
    if ! ntfsfix --force "${NTFS_PARTITION}"; then
      echo "[-] 无法修复NTFS分区"
      exit 1
    fi
  fi

  # 智能挂载策略
  local mount_opts="windows_names,uid=$(id -u),gid=$(id -g)"
  if [ -f "${ISO_PATH}" ]; then
    echo "[NTFS] 以只读模式挂载"
    mount -t ntfs-3g -o "ro,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || {
      echo "[!] 只读挂载失败，尝试读写模式"
      mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs"
    }
  else
    echo "[NTFS] 以读写模式挂载（用于下载ISO）"
    mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || {
      echo "[-] NTFS挂载失败"
      exit 1
    }
  fi

  # 二次验证
  if ! mountpoint -q "/root/ntfs"; then
    echo "[-] NTFS挂载最终失败"
    exit 1
  fi
}

# ======================
# ISO文件处理
# ======================
handle_iso() {
  echo "===== 处理ISO文件 ====="
  if [ ! -f "${ISO_PATH}" ]; then
    echo "[下载] 开始下载Manjaro ISO"
    mkdir -p "$(dirname "${ISO_PATH}")"
    if ! wget -q --show-progress -c -O "${ISO_PATH}.part" "${MANJARO_ISO_URL}"; then
      echo "[-] 下载失败，请检查："
      echo "    - 网络连接"
      echo "    - 磁盘空间（需要至少4GB可用空间）"
      exit 1
    fi
    mv "${ISO_PATH}.part" "${ISO_PATH}"
    echo "[校验] 下载完成，大小：$(du -h "${ISO_PATH}" | cut -f1)"
  else
    echo "[检测] 使用现有ISO文件：${ISO_PATH}"
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/7：环境检查 ====="
[ $EUID -ne 0 ] && { echo "[-] 需要root权限"; exit 1; }
[ ! -e "${TARGET_DISK}" ] && { echo "[-] 磁盘不存在: ${TARGET_DISK}"; exit 1; }

install_deps
mount_ntfs
handle_iso

echo "===== 步骤2/7：挂载ISO镜像 ====="
mkdir -p /mnt/iso
mount -o loop,ro "${ISO_PATH}" /mnt/iso || {
  echo "[-] ISO挂载失败，可能原因："
  echo "    1. 文件损坏（MD5: $(md5sum "${ISO_PATH}" | cut -d' ' -f1)）"
  echo "    2. 内核不支持loop设备（检查/dev/loop*）"
  exit 1
}

echo "===== 步骤3/7：准备系统分区 ====="
read -rp "即将格式化 ${TARGET_PARTITION}，确认继续？[y/N] " confirm
[[ "${confirm,,}" != "y" ]] && exit 0

mkfs.ext4 -F -L "SysRoot" "${TARGET_PARTITION}"
mkdir -p "${MOUNT_DIR}"
mount "${TARGET_PARTITION}" "${MOUNT_DIR}"

echo "===== 步骤4/7：安装基础系统 ====="
SFS_PATH="/mnt/iso/manjaro/x86_64/rootfs.sfs"
TEMP_MOUNT="/mnt/squashfs"

if mount -t squashfs -o loop,ro "${SFS_PATH}" "${TEMP_MOUNT}" 2>/dev/null; then
  echo "[复制] 同步系统文件..."
  rsync -aHAX --progress "${TEMP_MOUNT}/" "${MOUNT_DIR}/"
  umount "${TEMP_MOUNT}"
else
  echo "[解压] 使用bsdtar解压SquashFS"
  bsdtar -xpf "${SFS_PATH}" -C "${MOUNT_DIR}" || {
    echo "[-] 解压失败，建议安装squashfs-tools：apt install squashfs-tools"
    exit 1
  }
fi

echo "===== 步骤5/7：系统配置 ====="
echo "[配置] 生成fstab"
genfstab -U "${MOUNT_DIR}" > "${MOUNT_DIR}/etc/fstab"

echo "===== 步骤6/7：安装引导程序 ====="
for fs in dev proc sys; do
  mount --bind "/${fs}" "${MOUNT_DIR}/${fs}"
done

chroot "${MOUNT_DIR}" bash -c '
  grub-install --target=i386-pc --recheck "'"${TARGET_DISK}"'"
  grub-mkconfig -o /boot/grub/grub.cfg
'

echo "===== 步骤7/7：完成安装 ====="
echo -e "\n\e[32m[✓] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo "重启前操作建议："
echo "1. 检查挂载点：mount | grep -E '(${MOUNT_DIR}|/root/ntfs)'"
echo "2. 执行清理：umount -R ${MOUNT_DIR}"
echo "3. 重启系统：reboot"
