#!/bin/bash
set -e

# ======================
# 配置参数
# ======================
TARGET_DISK="/dev/sda"
TARGET_PARTITION="${TARGET_DISK}1"
NTFS_PARTITION="${TARGET_DISK}2"
MOUNT_DIR="/root/system"
ISO_PATH="/root/ntfs/iso/manjaro.iso"  # 修改后的ISO路径
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"
SFS_FILES=(
  "mhwdfs.sfs"
  "desktopfs.sfs"
  "rootfs.sfs"
)
GRUB_TARGET="i386-pc"

# ======================
# NTFS ISO检测
# ======================
check_iso() {
  mkdir -p /root/ntfs
  ntfsfix "$NTFS_PARTITION"
  mount -t ntfs-3g -o ro "$NTFS_PARTITION" /root/ntfs
  
  if [ -f "$ISO_PATH" ]; then
    echo "发现ISO缓存: $ISO_PATH"
    return 0
  else
    echo "未找到ISO文件，需要下载..."
    return 1
  fi
}

# ======================
# 分区处理
# ======================
prepare_partitions() {
  echo "格式化系统分区..."
  mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION"

  mkdir -p "$MOUNT_DIR"
  mount "$TARGET_PARTITION" "$MOUNT_DIR"
}

# ======================
# 文件系统合并
# ======================
merge_sfs_layers() {
  local WORK_DIR="/tmp/sfs_merge"
  mkdir -p "$WORK_DIR"/{layers,upper,work}

  # 挂载ISO获取sfs文件
  mkdir -p /mnt/iso
  mount -o loop /tmp/manjaro.iso /mnt/iso

  # 挂载所有SFS层
  for ((i=0; i<${#SFS_FILES[@]}; i++)); do
    sfs_file="/mnt/iso/$(find /mnt/iso -name ${SFS_FILES[i]} -print -quit)"
    layer_dir="$WORK_DIR/layers/layer$i"
    
    mkdir -p "$layer_dir"
    mount -t squashfs -o loop,ro "$sfs_file" "$layer_dir"
  done

  # 生成lowerdir参数（优先级从高到低）
  lower_dirs=$(find "$WORK_DIR/layers" -mindepth 1 -maxdepth 1 -type d | sort -r | tr '\n' ':')
  lower_dirs="${lower_dirs%:}"

  # 创建OverlayFS合并视图
  mount -t overlay overlay \
    -o lowerdir="$lower_dirs",upperdir="$WORK_DIR/upper",workdir="$WORK_DIR/work" \
    "$MOUNT_DIR"

  # 固化文件系统
  rsync -aHAX --delete "$MOUNT_DIR/" "$MOUNT_DIR/"
}

# ======================
# 系统配置
# ======================
configure_system() {
  # 基础挂载
  mount --bind /dev  "$MOUNT_DIR/dev"
  mount --bind /proc "$MOUNT_DIR/proc"
  mount --bind /sys  "$MOUNT_DIR/sys"
  mount --bind /run  "$MOUNT_DIR/run"

  # 生成fstab
  local root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
  echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

  # 安装引导
  chroot "$MOUNT_DIR" grub-install \
    --target="$GRUB_TARGET" \
    --recheck \
    "$TARGET_DISK"
  
  chroot "$MOUNT_DIR" grub-mkconfig \
    -o "/boot/grub/grub.cfg"
}

# ======================
# 主流程
# ======================
cleanup() {
  umount -R /mnt/iso 2>/dev/null || true
  umount -R /root/ntfs 2>/dev/null || true
  umount -R "$MOUNT_DIR" 2>/dev/null || true
  rm -rf /tmp/sfs_merge /tmp/manjaro.iso
}

check_prerequisites() {
  [ "$(id -u)" != "0" ] && { echo "需要root权限"; exit 1; }
  modprobe overlay || { echo "需要overlay支持"; exit 1; }
}

main() {
  trap cleanup EXIT
  check_prerequisites
  
  # 处理ISO
  if check_iso; then
    cp "$ISO_PATH" /tmp/manjaro.iso
  else
    wget --show-progress -O /tmp/manjaro.iso "$MANJARO_ISO_URL"
  fi

  prepare_partitions
  merge_sfs_layers
  configure_system

  echo -e "\n\e[32m安装成功！耗时: ${SECONDS}s\e[0m"
  read -rp "按回车重启..." -n1
  reboot
}

main "$@"
