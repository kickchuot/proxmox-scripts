#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# XPenology (DSM 7.2.x) VM creator for Proxmox VE, using the Arc loader
# (https://github.com/AuxXxilium/arc)
#
# Phong cách / quy ước theo community-scripts/ProxmoxVE (vm/ubuntu-vm.sh),
# nhưng hoàn toàn độc lập:
#   - KHÔNG source file ngoài (vm-core.func), KHÔNG gửi telemetry.
#   - Kết nối mạng duy nhất: github.com / api.github.com (+ CDN release của GitHub),
#     và apt CHỈ khi thiếu công cụ cần thiết.
#
# Biến môi trường tuỳ chọn:
#   VERBOSE=yes          hiện toàn bộ output của qm/pvesm
#   GITHUB_TOKEN=...     token GitHub (chỉ để tránh rate limit của API)
#   ARC_IMG_PATH=/path   dùng file arc.img / .img.zip / .img.gz có sẵn (bỏ qua tải)
#   ARC_ASSET_NAME=name  ép chọn đúng tên asset của release (nếu tự chọn sai)
#
# License: MIT
# -----------------------------------------------------------------------------

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

SCRIPT_VERSION="1.0.0"
APP="XPenology DSM (Arc loader)"
ARC_REPO="AuxXxilium/arc"
ARC_API="https://api.github.com/repos/${ARC_REPO}/releases/latest"
BACKTITLE="Proxmox VE Helper Scripts"

# ---- Mặc định (nguồn: xem bảng cấu hình trong tài liệu kèm theo) ----------
LOADER_MIN_GIB=4          # README Arc: "A disk for the loader, 4 GB or more"
MAX_DATA_SATA=5           # sata0 = loader; PVE chỉ có sata0..sata5 (nootch.net)
DEFAULT_CORES=2           # nootch: "minimum of 2"
DEFAULT_RAM=4096          # nootch: "minimum of 4GB"
DEFAULT_VDISK_GIB=32      # arc/docker.md: DISK_SIZE "32G"
DEFAULT_CPU="x86-64-v2-AES"
DEFAULT_NIC="virtio"
DEFAULT_MACHINE="i440fx"
VERBOSE="${VERBOSE:-no}"

# ---- Màu sắc / icon -------------------------------------------------------
YW=$'\033[33m'; BL=$'\033[36m'; RD=$'\033[01;31m'; GN=$'\033[1;92m'
DGN=$'\033[32m'; CL=$'\033[m'; BOLD=$'\033[1m'; BFR=$'\r\033[K'
CM="${GN}✔️${CL}"; CROSS="${RD}✖️${CL}"; WARN="${YW}⚠️${CL}"

# ---- Trạng thái toàn cục --------------------------------------------------
TEMP_DIR=""
LOG_FILE=""
VM_CREATED=0      # =1 ngay sau khi `qm create` thành công (để biết có cần huỷ khi lỗi)
VM_DONE=0         # =1 khi VM đã cấu hình xong (từ đây lỗi/Ctrl-C KHÔNG huỷ VM nữa)
VMID=""; HN=""; CORE_COUNT=""; RAM_SIZE=""; BRG=""; MAC=""; VLAN=""; VLAN_OPT=""
NIC_MODEL=""; CPU_TYPE=""; MACHINE_TYPE=""; STORAGE=""; VDISK_SIZE_GB=""; METHOD=""
ARC_IMG=""; ARC_TAG="unknown"
declare -A STG_TYPE=() STG_FREE=()
STG_LIST=()
SATA_USED=0                 # số slot sata dữ liệu đã dùng (sata1..)
SATA_DISKS=()               # "sataN=<giá trị qm set>"
HBA_ADDRS=()                # địa chỉ PCI của controller passthrough
DATA_DESC=()                # mô tả hiển thị trong phần tóm tắt

# =============================================================================
# Hàm hiển thị
# =============================================================================
msg_info()  { echo -ne " ⏳ ${YW}$1...${CL}"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }
msg_warn()  { echo -e "${BFR} ${WARN} ${YW}$1${CL}"; }

header_info() {
  clear
  cat <<"EOF"
 __  ______  _____ _   _  ___  _      ___   ______   __
 \ \/ /  _ \| ____| \ | |/ _ \| |    / _ \ / ___\ \ / /
  \  /| |_) |  _| |  \| | | | | |   | | | | |  _ \ V /
  /  \|  __/| |___| |\  | |_| | |___| |_| | |_| | | |
 /_/\_\_|   |_____|_| \_|\___/|_____|\___/ \____| |_|
          DSM 7.2.x  •  Arc loader  •  Proxmox VE
EOF
  echo
}

# Chạy lệnh yên lặng, log vào file; nếu lỗi thì in 15 dòng cuối của log
silent() {
  if [[ $VERBOSE == yes ]]; then "$@"; return; fi
  local rc=0
  "$@" >>"$LOG_FILE" 2>&1 || rc=$?
  if ((rc != 0)); then
    msg_error "Command failed (exit ${rc}): $*"
    tail -n 15 "$LOG_FILE" >&2 || true
  fi
  return "$rc"
}

# =============================================================================
# trap / dọn dẹp / huỷ VM dở dang
# =============================================================================
error_handler() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  echo -e "\n ${CROSS} ${RD}[ERROR]${CL} line ${line}, exit code ${rc}: ${YW}${cmd}${CL}"
  exit "$rc"
}

cleanup() {
  local rc=$?
  trap - ERR EXIT INT TERM
  set +eu +o pipefail
  # Chỉ huỷ khi: có lỗi + VM do CHÍNH lần chạy này tạo + chưa cấu hình xong.
  if ((rc != 0)) && [[ $VM_CREATED == 1 && $VM_DONE == 0 && -n $VMID ]]; then
    echo
    msg_warn "Removing partially created VM ${VMID}"
    qm stop "$VMID" --skiplock >/dev/null 2>&1
    # Lưu ý: ổ passthrough (/dev/disk/by-id/...) KHÔNG phải volume của PVE nên không bị xoá dữ liệu.
    if qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1 >/dev/null 2>&1; then
      msg_ok "VM ${VMID} removed"
    else
      msg_error "Could not remove VM ${VMID} automatically. Remove it manually: qm destroy ${VMID} --purge 1 --destroy-unreferenced-disks 1"
    fi
  fi
  [[ -n $TEMP_DIR && -d $TEMP_DIR ]] && rm -rf "$TEMP_DIR"
  return 0
}

exit_script() {
  echo -e "\n ${CROSS} ${RD}User exited script${CL}\n"
  exit 0
}

TEMP_DIR=$(mktemp -d "${TMPDIR:-/var/tmp}/xpenology-vm.XXXXXX")
LOG_FILE="${TEMP_DIR}/install.log"
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'echo; msg_error "Interrupted (SIGINT)"; exit 130' INT
trap 'echo; msg_error "Terminated (SIGTERM)"; exit 143' TERM

# =============================================================================
# whiptail helpers.  Mọi hàm trả kết quả qua nameref (KHÔNG dùng $(...)) để
# exit_script thoát được shell chính.
# =============================================================================
wt() { whiptail --backtitle "$BACKTITLE" "$@"; }

confirm() { # title text [h] [w] -> 0=yes
  wt --title "$1" --yesno "$2" "${3:-12}" "${4:-70}"
}

ask_input() { # var title prompt default
  local -n _out=$1
  _out=$(wt --title "$2" --inputbox "$3" 11 66 "$4" 3>&1 1>&2 2>&3) || exit_script
}

ask_valid() { # var title prompt default validator errmsg
  local -n _v=$1
  local val def=$4
  while :; do
    ask_input val "$2" "$3" "$def"
    if "$5" "$val"; then _v=$val; return 0; fi
    wt --title "INVALID INPUT" --msgbox "$6" 10 66
    def=$val
  done
}

select_radio() { # var title prompt default tag1 desc1 tag2 desc2 ...
  local -n _r=$1
  local title=$2 prompt=$3 def=$4
  shift 4
  local -a items=()
  local tag desc st
  while (($# >= 2)); do
    tag=$1; desc=$2; shift 2
    st=OFF; [[ $tag == "$def" ]] && st=ON
    items+=("$tag" "$desc" "$st")
  done
  local n=$((${#items[@]} / 3))
  _r=$(wt --title "$title" --radiolist "$prompt" $((n + 9)) 78 "$n" "${items[@]}" 3>&1 1>&2 2>&3) || exit_script
}

# =============================================================================
# Validators
# =============================================================================
is_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
is_cores()    { [[ $1 =~ ^[1-9][0-9]?$ ]]; }
is_ram()      { [[ $1 =~ ^[1-9][0-9]{3,6}$ ]] && (($1 >= 2048)); }
is_size()     { [[ $1 =~ ^[1-9][0-9]{0,5}$ ]]; }
is_vlan()     { [[ -z $1 ]] || { [[ $1 =~ ^[1-9][0-9]{0,3}$ ]] && (($1 <= 4094)); }; }
is_mac() {
  [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || return 1
  (((16#${1:0:2} & 1) == 0)) # bit multicast phải = 0
}
is_file_based() { case $1 in dir | nfs | cifs | btrfs | glusterfs | cephfs) return 0 ;; *) return 1 ;; esac; }

# =============================================================================
# Kiểm tra môi trường
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root on the Proxmox VE node."
    exit 1
  fi
}

check_tty() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    msg_error "An interactive terminal is required (whiptail). Run it as: bash -c \"\$(curl -fsSL <URL>)\""
    exit 1
  fi
}

check_pve() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "This is not a Proxmox VE host (pveversion not found)."
    exit 1
  fi
  local out major minor
  out=$(pveversion)
  if [[ $out =~ pve-manager/([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  else
    msg_error "Cannot parse Proxmox VE version: ${out}"
    exit 1
  fi
  # Hỗ trợ: 8.x và 9.x (x86_64). Các bản khác: cảnh báo + hỏi.
  if ((major < 8 || major > 9)); then
    if ! confirm "UNSUPPORTED PVE VERSION" "Detected Proxmox VE ${major}.${minor}.\n\nThis script targets Proxmox VE 8.x and 9.x.\nContinue anyway at your own risk?" 12 64; then
      exit_script
    fi
  fi
  PVE_VERSION="${major}.${minor}"
}

check_arch() {
  if [[ $(dpkg --print-architecture) != "amd64" ]]; then
    msg_error "Only amd64 is supported (XPenology/Arc is x86-64 only)."
    exit 1
  fi
}

check_network() {
  msg_info "Checking connectivity to GitHub"
  if ! curl -fsSI --max-time 10 https://github.com >/dev/null 2>&1; then
    msg_error "No internet connectivity to github.com."
    exit 1
  fi
  msg_ok "GitHub is reachable"
}

check_kvm() {
  if [[ ! -e /dev/kvm ]]; then
    msg_warn "/dev/kvm not found: hardware virtualization (VT-x/AMD-V) seems disabled. The VM will not start."
  fi
}

ensure_tools() {
  local -a pkgs=()
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v unzip >/dev/null 2>&1 || pkgs+=(unzip)
  command -v gzip >/dev/null 2>&1 || pkgs+=(gzip)
  command -v lspci >/dev/null 2>&1 || pkgs+=(pciutils)
  command -v whiptail >/dev/null 2>&1 || pkgs+=(whiptail)
  command -v sfdisk >/dev/null 2>&1 || pkgs+=(fdisk)
  command -v sha256sum >/dev/null 2>&1 || pkgs+=(coreutils)
  perl -MJSON -e1 >/dev/null 2>&1 || pkgs+=(libjson-perl) # parse JSON của GitHub API
  if ((${#pkgs[@]} > 0)); then
    msg_info "Installing missing tools: ${pkgs[*]}"
    silent apt-get update -qq || msg_warn "apt-get update failed (repo/subscription?). Trying to install anyway"
    silent apt-get install -y -qq "${pkgs[@]}"
    msg_ok "Installed: ${pkgs[*]}"
  fi
}

# =============================================================================
# Tìm ID / storage / bridge
# =============================================================================
vmid_in_use() {
  local id=$1 res lv zf
  [[ -f /etc/pve/qemu-server/${id}.conf || -f /etc/pve/lxc/${id}.conf ]] && return 0
  res=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true)
  if grep -Eq "\"vmid\"[[:space:]]*:[[:space:]]*${id}([^0-9]|\$)" <<<"$res"; then return 0; fi
  # volume mồ côi còn sót lại của ID này (LVM / ZFS)
  lv=$(lvs --noheadings -o lv_name 2>/dev/null || true)
  if grep -Eq "(vm|base)-${id}-(disk|cloudinit)" <<<"$lv"; then return 0; fi
  if command -v zfs >/dev/null 2>&1; then
    zf=$(zfs list -H -o name 2>/dev/null || true)
    if grep -Eq "(vm|base|subvol)-${id}-(disk|cloudinit)" <<<"$zf"; then return 0; fi
  fi
  return 1
}

get_valid_nextid() {
  local id
  id=$(pvesh get /cluster/nextid)
  while vmid_in_use "$id"; do id=$((id + 1)); done
  echo "$id"
}

is_vmid_ok() { [[ $1 =~ ^[1-9][0-9]{2,8}$ ]] && ! vmid_in_use "$1"; }

load_storages() {
  local out name type status free
  out=$(pvesm status -content images -enabled 1 2>/dev/null || true)
  while read -r name type status _ _ free _; do
    [[ $name == "Name" || -z $name ]] && continue
    [[ $status == "active" ]] || continue
    STG_TYPE[$name]=$type
    STG_FREE[$name]=${free:-0}
    STG_LIST+=("$name")
  done <<<"$out"
  if ((${#STG_LIST[@]} == 0)); then
    msg_error "No active storage with content type 'Disk image' found (Datacenter → Storage)."
    exit 1
  fi
}

# Chọn storage: nếu chỉ có 1 thì tự dùng, không hỏi
pick_storage() { # var title prompt default
  local -n _s=$1
  local def=$4 s best="" bestfree=-1
  if ((${#STG_LIST[@]} == 1)); then _s=${STG_LIST[0]}; return 0; fi
  if [[ -z $def ]]; then
    for s in "${STG_LIST[@]}"; do
      if ((STG_FREE[$s] > bestfree)); then best=$s; bestfree=${STG_FREE[$s]}; fi
    done
    def=$best
  fi
  local -a items=()
  for s in "${STG_LIST[@]}"; do
    items+=("$s" "type=${STG_TYPE[$s]}, free=$((STG_FREE[$s] / 1024 / 1024)) GiB")
  done
  select_radio _s "$2" "$3" "$def" "${items[@]}"
}

list_bridges() {
  local b
  for b in /sys/class/net/*/bridge; do
    b=${b%/bridge}
    echo "${b##*/}"
  done
}

gen_mac() {
  printf '02:%02X:%02X:%02X:%02X:%02X' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

# =============================================================================
# Cấu hình VM: Default / Advanced
# =============================================================================
select_bridge() {
  local -a br=()
  mapfile -t br < <(list_bridges)
  if ((${#br[@]} == 0)); then
    msg_error "No Linux bridge found on this node (create one in Node → Network)."
    exit 1
  fi
  if ((${#br[@]} == 1)) || [[ $METHOD == default ]]; then
    BRG=${br[0]}
    return 0
  fi
  local -a items=()
  local b
  for b in "${br[@]}"; do items+=("$b" "Linux bridge"); done
  select_radio BRG "BRIDGE" "Select the network bridge" "${br[0]}" "${items[@]}"
}

default_settings() {
  METHOD=default
  VMID=$(get_valid_nextid)
  HN="xpenology"
  CORE_COUNT=$DEFAULT_CORES
  RAM_SIZE=$DEFAULT_RAM
  CPU_TYPE=$DEFAULT_CPU
  NIC_MODEL=$DEFAULT_NIC
  MACHINE_TYPE=$DEFAULT_MACHINE
  VDISK_SIZE_GB=$DEFAULT_VDISK_GIB
  MAC=$(gen_mac)
  VLAN=""
  select_bridge
  pick_storage STORAGE "LOADER STORAGE" "Select the storage for the Arc loader disk" ""
}

advanced_settings() {
  METHOD=advanced
  ask_valid VMID "VIRTUAL MACHINE ID" "Virtual Machine ID (a free ID is suggested; existing VMs are NEVER overwritten)" "$(get_valid_nextid)" is_vmid_ok \
    "This ID is invalid or already in use (VM, CT or leftover volumes).\nThis script never overwrites an existing VM. Choose another ID."
  ask_valid HN "HOSTNAME" "Hostname (lowercase letters, digits, hyphen)" "xpenology" is_hostname \
    "Invalid hostname. Use lowercase letters, digits and hyphens (max 63 chars)."
  ask_valid CORE_COUNT "CPU CORES" "Allocate CPU cores (recommended >= 2)" "$DEFAULT_CORES" is_cores "Enter a number between 1 and 99."
  ask_valid RAM_SIZE "RAM" "Allocate RAM in MiB (recommended >= 4096)" "$DEFAULT_RAM" is_ram "Enter RAM in MiB, minimum 2048."
  select_radio CPU_TYPE "CPU MODEL" "Select the CPU model" "$DEFAULT_CPU" \
    "x86-64-v2-AES" "Recommended (used in the reference guide)" \
    "host" "Pass through the host CPU model (not migratable)"
  select_radio MACHINE_TYPE "MACHINE TYPE" "Select the machine type" "$DEFAULT_MACHINE" \
    "i440fx" "Proxmox default (used in the reference guide)" \
    "q35" "PCIe machine (hostpci gets pcie=1)"
  select_radio NIC_MODEL "NETWORK CARD" "Select the NIC model" "$DEFAULT_NIC" \
    "virtio" "VirtIO paravirtualized (default)" \
    "e1000" "Intel E1000 (fallback if VirtIO gets no link in Arc)" \
    "e1000e" "Intel E1000e"
  select_bridge
  ask_valid MAC "MAC ADDRESS" "MAC address (unicast, format AA:BB:CC:DD:EE:FF)" "$(gen_mac)" is_mac "Invalid MAC address (or multicast bit set)."
  ask_valid VLAN "VLAN" "VLAN tag (leave empty for none)" "" is_vlan "Enter a VLAN between 1 and 4094, or leave empty."
  pick_storage STORAGE "LOADER STORAGE" "Select the storage for the Arc loader disk" ""
  ask_valid VDISK_SIZE_GB "VIRTUAL DATA DISK SIZE" "Default size (GiB) for virtual data disks, used if you choose virtual disks later" "$DEFAULT_VDISK_GIB" is_size \
    "Enter a positive integer (GiB)."
}

start_script() {
  local rc=0
  wt --title "XPENOLOGY VM" --yes-button "Default" --no-button "Advanced" --yesno \
    "Create an XPenology (DSM 7.2.x) VM with the latest Arc loader.\n\nUse Default Settings?\n\nDefaults:\n  • ${DEFAULT_CORES} CPU cores, $((DEFAULT_RAM / 1024)) GB RAM\n  • Loader disk on sata0 (>= ${LOADER_MIN_GIB} GB)\n  • SeaBIOS, ${DEFAULT_MACHINE}, CPU ${DEFAULT_CPU}, ${DEFAULT_NIC} NIC\n  • Storage / bridge / data disks are chosen next" 17 66 || rc=$?
  case $rc in
    0) default_settings ;;
    1) advanced_settings ;;
    *) exit_script ;;
  esac
  [[ -n $VLAN ]] && VLAN_OPT=",tag=${VLAN}"
  return 0
}

# =============================================================================
# Ổ dữ liệu: disk ảo / passthrough disk / passthrough controller
# =============================================================================
add_sata() { # value -> in ra "sataN"
  SATA_USED=$((SATA_USED + 1))
  SATA_DISKS+=("sata${SATA_USED}=$1")
}

free_sata_slots() { echo $((MAX_DATA_SATA - SATA_USED)); }

# Ổ có đang được host dùng không (mount, LVM PV, ZFS pool)? 0 = đang dùng
host_disk_in_use() {
  local dev=$1 id=${2:-} mp pvs_out zp
  mp=$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null || true)
  if [[ -n ${mp//[$' \n']/} ]]; then return 0; fi
  if command -v pvs >/dev/null 2>&1; then
    pvs_out=$(pvs --noheadings -o pv_name 2>/dev/null || true)
    if grep -Eq "^[[:space:]]*${dev}(p?[0-9]+)?[[:space:]]*$" <<<"$pvs_out"; then return 0; fi
  fi
  if command -v zpool >/dev/null 2>&1; then
    zp=$(zpool status -P 2>/dev/null || true)
    if grep -Fq -- "$dev" <<<"$zp"; then return 0; fi
    if [[ -n $id ]] && grep -Fq -- "$id" <<<"$zp"; then return 0; fi
  fi
  return 1
}

disk_has_data() { # 0 = có phân vùng/filesystem
  local info
  info=$(lsblk -nr -o TYPE,FSTYPE "$1" 2>/dev/null || true)
  if grep -Eq '^part|[[:space:]][^[:space:]]+$' <<<"$info"; then return 0; fi
  return 1
}

configure_virtual_disks() {
  local free cnt size dstore i fmt=""
  free=$(free_sata_slots)
  if ((free < 1)); then
    wt --title "NO FREE SLOT" --msgbox "No free SATA slot left (sata1-sata${MAX_DATA_SATA} are in use)." 8 60
    return 0
  fi
  ask_valid cnt "VIRTUAL DISKS" "How many virtual data disks? (1-${free})" "1" \
    "_cnt_ok" "Enter a number between 1 and ${free}."
  ask_valid size "VIRTUAL DISK SIZE" "Size of EACH virtual disk in GiB" "$VDISK_SIZE_GB" is_size "Enter a positive integer (GiB)."
  pick_storage dstore "DATA STORAGE" "Select the storage for the virtual data disks" "$STORAGE"
  # dir/nfs/cifs/btrfs: chỉ định rõ raw; lvm-thin/zfspool: PVE tự dùng volume block, không cần format
  is_file_based "${STG_TYPE[$dstore]}" && fmt=",format=raw"
  for ((i = 1; i <= cnt; i++)); do
    add_sata "${dstore}:${size}${fmt}"
    DATA_DESC+=("Virtual disk ${size} GiB on '${dstore}' (${STG_TYPE[$dstore]}) → sata${SATA_USED}")
  done
}
_cnt_ok() { [[ $1 =~ ^[1-9][0-9]?$ ]] && (($1 <= $(free_sata_slots))); }

configure_passthrough_disks() {
  local free
  free=$(free_sata_slots)
  if ((free < 1)); then
    wt --title "NO FREE SLOT" --msgbox "No free SATA slot left for passthrough disks." 8 60
    return 0
  fi
  msg_info "Scanning physical disks"
  local used_confs p id dev size model tag state
  used_confs=$(grep -rhs "/dev/disk/by-id/" /etc/pve/nodes/ 2>/dev/null || true)
  local -A seen=() has_data=()
  local -a items=() ids=()
  for p in /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-* /dev/disk/by-id/nvme-*; do
    [[ $p == *-part* ]] && continue
    id=${p##*/}
    [[ $id == nvme-eui.* ]] && continue
    dev=$(readlink -f "$p")
    [[ -b $dev ]] || continue
    [[ -n ${seen[$dev]:-} ]] && continue
    seen[$dev]=1
    host_disk_in_use "$dev" "$id" && continue            # ổ của Proxmox: không bao giờ liệt kê
    grep -Fq -- "$id" <<<"$used_confs" && continue        # đã gắn cho VM khác
    size=$(lsblk -dnr -o SIZE "$dev")
    model=$(lsblk -dn -o MODEL "$dev" | sed 's/[[:space:]]*$//')
    if disk_has_data "$dev"; then state="[HAS DATA]"; has_data[$id]=1; else state="[blank]"; fi
    items+=("$id" "${size} ${model} ${state}" OFF)
    ids+=("$id")
  done
  msg_ok "Found ${#ids[@]} candidate disk(s)"
  if ((${#ids[@]} == 0)); then
    wt --title "NO DISKS" --msgbox "No unused physical disks found.\n\n(Disks mounted by the host, used by LVM/ZFS or already attached to another VM are hidden.)" 11 66
    return 0
  fi
  local sel
  local -a chosen=()
  while :; do
    sel=$(wt --title "PASSTHROUGH DISKS" --separate-output --checklist \
      "Select physical disks to pass to DSM (max ${free}). SPACE = toggle.\nDisks are referenced by /dev/disk/by-id (stable across reboots)." \
      $((${#ids[@]} + 10 > 22 ? 22 : ${#ids[@]} + 10)) 110 "${#ids[@]}" "${items[@]}" 3>&1 1>&2 2>&3) || exit_script
    mapfile -t chosen <<<"$sel"
    [[ -z ${chosen[0]:-} ]] && chosen=()
    if ((${#chosen[@]} > free)); then
      wt --title "TOO MANY DISKS" --msgbox "You selected ${#chosen[@]} disks but only ${free} SATA slot(s) are free." 9 60
      continue
    fi
    break
  done
  ((${#chosen[@]} == 0)) && return 0

  local list="" any_data=0
  for id in "${chosen[@]}"; do
    list+="  • ${id}\n"
    [[ -n ${has_data[$id]:-} ]] && any_data=1
  done
  if ((any_data)); then
    local typed
    ask_input typed "⚠ DESTRUCTIVE: DISKS WITH DATA" \
      "These disks will be handed to DSM and WILL BE ERASED/FORMATTED when you create a storage pool:\n\n${list}\nAt least one of them already contains partitions/filesystems.\nType YES (uppercase) to confirm." ""
    if [[ $typed != "YES" ]]; then
      msg_warn "Not confirmed: passthrough disk step skipped"
      return 0
    fi
  else
    confirm "CONFIRM PASSTHROUGH" "These disks will be handed to DSM exclusively:\n\n${list}\nContinue?" $((10 + ${#chosen[@]})) 90 || { msg_warn "Passthrough disk step skipped"; return 0; }
  fi
  for id in "${chosen[@]}"; do
    # backup=0: tránh vzdump vô tình sao lưu cả ổ vật lý
    add_sata "/dev/disk/by-id/${id},backup=0"
    DATA_DESC+=("Passthrough disk ${id} → sata${SATA_USED}")
  done
}

iommu_enabled() {
  [[ -d /sys/kernel/iommu_groups ]] && [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]
}

controller_disks() { # in ra tên block-device (sda, nvme0n1...) thuộc controller PCI $1
  local b p
  for b in /sys/block/*; do
    p=$(readlink -f "$b")
    if [[ $p == *"/$1/"* ]]; then echo "${b##*/}"; fi
  done
  return 0
}

iommu_siblings() { # các thiết bị KHÁC slot nằm chung IOMMU group
  local addr=$1 d out=""
  for d in /sys/bus/pci/devices/"$addr"/iommu_group/devices/*; do
    d=${d##*/}
    if [[ $d != "$addr" && ${d%.*} != "${addr%.*}" ]]; then out+="${d} "; fi
  done
  echo "$out"
}

configure_hba() {
  if ! iommu_enabled; then
    wt --title "IOMMU NOT ENABLED" --msgbox \
      "IOMMU does not appear to be enabled on this host (/sys/kernel/iommu_groups is empty).\n\nPCI passthrough will NOT work until you:\n  1. enable VT-d / AMD-Vi in the BIOS/UEFI,\n  2. add the IOMMU kernel parameter and reboot.\n\nSee https://pve.proxmox.com/wiki/PCI_Passthrough\n\nThe controller passthrough step is skipped." 17 74
    msg_warn "IOMMU not enabled: controller passthrough skipped"
    return 0
  fi
  msg_info "Scanning storage controllers"
  local lspci_out line addr desc d disks inuse
  lspci_out=$(lspci -nnD 2>/dev/null | grep -Ei 'SATA controller|SAS controller|Serial Attached SCSI|RAID bus controller|Mass storage controller|Non-Volatile memory controller' || true)
  local -a items=() addrs=()
  local -A hba_disks=()
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    addr=${line%% *}
    desc=${line#* }
    disks=""; inuse=0
    for d in $(controller_disks "$addr"); do
      disks+="${d} "
      host_disk_in_use "/dev/${d}" && inuse=1
    done
    ((inuse)) && continue                       # controller đang chứa ổ của Proxmox → không cho passthrough
    hba_disks[$addr]=$disks
    items+=("$addr" "${desc:0:62} | disks: ${disks:-none detected}" OFF)
    addrs+=("$addr")
  done <<<"$lspci_out"
  msg_ok "Found ${#addrs[@]} passthrough-able controller(s)"
  if ((${#addrs[@]} == 0)); then
    wt --title "NO CONTROLLER" --msgbox "No storage controller available for passthrough.\n\n(Controllers holding disks mounted/used by Proxmox are hidden.)" 10 66
    return 0
  fi
  local sel
  local -a chosen=()
  sel=$(wt --title "PASSTHROUGH CONTROLLER (HBA)" --separate-output --checklist \
    "Select SATA/SAS/NVMe controller(s) to pass entirely to the VM.\nAll disks on a controller disappear from the host." \
    $((${#addrs[@]} + 10 > 22 ? 22 : ${#addrs[@]} + 10)) 120 "${#addrs[@]}" "${items[@]}" 3>&1 1>&2 2>&3) || exit_script
  mapfile -t chosen <<<"$sel"
  [[ -z ${chosen[0]:-} ]] && chosen=()
  ((${#chosen[@]} == 0)) && return 0

  local list="" sib typed
  for addr in "${chosen[@]}"; do
    list+="  • ${addr}  (disks: ${hba_disks[$addr]:-none detected})\n"
    sib=$(iommu_siblings "$addr")
    [[ -n $sib ]] && list+="      ⚠ shares its IOMMU group with: ${sib}\n"
  done
  ask_input typed "⚠ DESTRUCTIVE: CONTROLLER PASSTHROUGH" \
    "The whole controller(s) below will be detached from Proxmox and given to the VM:\n\n${list}\nAny disk on them can be ERASED by DSM. Devices sharing an IOMMU group are passed together.\nType YES (uppercase) to confirm." ""
  if [[ $typed != "YES" ]]; then
    msg_warn "Not confirmed: controller passthrough step skipped"
    return 0
  fi
  for addr in "${chosen[@]}"; do
    HBA_ADDRS+=("$addr")
    DATA_DESC+=("Passthrough controller ${addr} (disks: ${hba_disks[$addr]:-none detected})")
  done
}

choose_data_disks() {
  local methods
  methods=$(wt --title "DATA DISKS" --separate-output --checklist \
    "How should DSM get its data disks? (SPACE = toggle, you can combine, or select nothing to skip)\n\nLoader = sata0. Data disks use sata1-sata${MAX_DATA_SATA}." 16 82 3 \
    "virtual" "Virtual disk(s) on a Proxmox storage" OFF \
    "disks" "Passthrough physical disk(s) via /dev/disk/by-id" OFF \
    "hba" "Passthrough a SATA/SAS/NVMe controller (PCI, needs IOMMU)" OFF 3>&1 1>&2 2>&3) || exit_script
  [[ $methods == *disks* ]] && configure_passthrough_disks
  [[ $methods == *virtual* ]] && configure_virtual_disks
  [[ $methods == *hba* ]] && configure_hba
  if ((${#DATA_DESC[@]} == 0)); then
    msg_warn "No data disks selected: you can add them later with 'qm set ${VMID} -sata1 ...'"
  fi
  return 0
}

# =============================================================================
# Tóm tắt trước khi tạo
# =============================================================================
print_summary() {
  local l
  echo -e "\n ${BOLD}${DGN}Summary (${METHOD} settings)${CL}"
  printf "  ${DGN}%-20s${CL} ${BL}%s${CL}\n" "VM ID" "$VMID" "Hostname" "$HN" \
    "BIOS / Machine" "SeaBIOS / ${MACHINE_TYPE}" "CPU" "${CPU_TYPE} × ${CORE_COUNT} cores" "RAM" "${RAM_SIZE} MiB (balloon off)" \
    "NIC" "${NIC_MODEL}, bridge ${BRG}, MAC ${MAC}${VLAN:+, VLAN ${VLAN}}" \
    "Loader disk" "sata0 on '${STORAGE}' (${STG_TYPE[$STORAGE]}), >= ${LOADER_MIN_GIB} GiB" \
    "Boot order" "sata0" "Start at boot" "yes"
  if ((${#DATA_DESC[@]} > 0)); then
    for l in "${DATA_DESC[@]}"; do printf "  ${DGN}%-20s${CL} ${BL}%s${CL}\n" "Data" "$l"; done
  else
    printf "  ${DGN}%-20s${CL} ${BL}%s${CL}\n" "Data" "none"
  fi
  echo
}

# =============================================================================
# Tải & chuẩn bị Arc loader
# =============================================================================
select_asset() { # $1 = file TSV (ASSET\tname\tsize\turl\tdigest)
  local -a names=() sizes=() urls=() digests=()
  local kind n s u d
  while IFS=$'\t' read -r kind n s u d; do
    [[ $kind == ASSET ]] || continue
    names+=("$n"); sizes+=("$s"); urls+=("$u"); digests+=("$d")
  done <"$1"
  if ((${#names[@]} == 0)); then
    msg_error "The latest release has no assets."
    exit 1
  fi
  local idx=-1 i re
  if [[ -n ${ARC_ASSET_NAME:-} ]]; then
    for i in "${!names[@]}"; do
      if [[ ${names[$i]} == "$ARC_ASSET_NAME" ]]; then idx=$i; break; fi
    done
  else
    # Ưu tiên: arc*.img.zip → arc*.img.gz → arc*.img → bất kỳ *.img.zip / *.img.gz
    local -a tiers=('^arc[^/]*\.img\.zip$' '^arc[^/]*\.img\.gz$' '^arc[^/]*\.img$' '\.img\.zip$' '\.img\.gz$')
    local excl='essential|beta|update|vmdk|ova|vhd|qcow|vdi|\.sha|checksum|\.txt|\.md5|\.sig'
    local lname
    for re in "${tiers[@]}"; do
      for i in "${!names[@]}"; do
        lname=${names[$i],,}
        if [[ $lname =~ $re ]] && ! [[ $lname =~ $excl ]]; then idx=$i; break 2; fi
      done
    done
  fi
  if ((idx < 0)); then
    msg_error "Could not find an Arc loader image among the release assets:"
    printf '    - %s\n' "${names[@]}" >&2
    echo "    Re-run with ARC_ASSET_NAME=<exact asset name> to force a choice." >&2
    exit 1
  fi
  ASSET_NAME=${names[$idx]}; ASSET_SIZE=${sizes[$idx]}; ASSET_URL=${urls[$idx]}; ASSET_DIGEST=${digests[$idx]}
}

fetch_release_metadata() {
  local hdr="${TEMP_DIR}/gh.hdr" body="${TEMP_DIR}/release.json" code remaining reset
  local -a auth=()
  if [[ -n ${GITHUB_TOKEN:-} ]]; then auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); fi
  code=$(curl -sS --max-time 30 --retry 2 -D "$hdr" -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${auth[@]}" "$ARC_API") || code=000
  case $code in
    200) ;;
    403 | 429)
      remaining=$(tr -d '\r' <"$hdr" | awk -F': ' 'tolower($1)=="x-ratelimit-remaining"{print $2}')
      reset=$(tr -d '\r' <"$hdr" | awk -F': ' 'tolower($1)=="x-ratelimit-reset"{print $2}')
      msg_error "GitHub API refused the request (HTTP ${code}${remaining:+, rate-limit remaining ${remaining}})."
      if [[ -n $reset ]]; then echo "    Limit resets at: $(date -d "@${reset}" '+%F %T %Z' 2>/dev/null || echo "$reset")" >&2; fi
      echo "    Wait, or export GITHUB_TOKEN=<token> to raise the limit, or use ARC_IMG_PATH=<local file>." >&2
      exit 1
      ;;
    404) msg_error "Release not found (HTTP 404) at ${ARC_API}"; exit 1 ;;
    000) msg_error "Network error while contacting api.github.com"; exit 1 ;;
    *) msg_error "Unexpected HTTP ${code} from the GitHub API"; exit 1 ;;
  esac
  # Parse bằng perl+JSON (có sẵn trên PVE) → TSV
  perl -MJSON -e '
    local $/; my $j = decode_json(<STDIN>);
    print "TAG\t", ($j->{tag_name} // ""), "\n";
    for my $a (@{ $j->{assets} // [] }) {
      print join("\t", "ASSET", $a->{name}, $a->{size} // 0, $a->{browser_download_url}, $a->{digest} // ""), "\n";
    }' <"$body" >"${TEMP_DIR}/assets.tsv"
  ARC_TAG=$(awk -F'\t' '$1=="TAG"{print $2}' "${TEMP_DIR}/assets.tsv")
  select_asset "${TEMP_DIR}/assets.tsv"
}

download_loader() { # đặt DL_FILE
  if [[ -n ${ARC_IMG_PATH:-} ]]; then
    [[ -f $ARC_IMG_PATH ]] || { msg_error "ARC_IMG_PATH not found: ${ARC_IMG_PATH}"; exit 1; }
    DL_FILE=$ARC_IMG_PATH
    ARC_TAG="local-file"
    msg_ok "Using local loader image: ${DL_FILE}"
    return 0
  fi
  msg_info "Querying latest Arc release (${ARC_REPO})"
  fetch_release_metadata
  msg_ok "Latest Arc release: ${ARC_TAG} → asset ${ASSET_NAME} ($((ASSET_SIZE / 1024 / 1024)) MiB)"

  local avail need
  avail=$(df -Pm "$TEMP_DIR" | awk 'NR==2{print $4}')
  need=$((ASSET_SIZE / 1024 / 1024 * 2 + 1024))
  if ((avail < need)); then
    msg_error "Not enough free space in ${TEMP_DIR}: ${avail} MiB available, ~${need} MiB needed. Set TMPDIR to a bigger filesystem."
    exit 1
  fi

  DL_FILE="${TEMP_DIR}/${ASSET_NAME}"
  echo -e " ⏳ ${YW}Downloading ${ASSET_NAME}...${CL}"
  curl -fL --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 15 --progress-bar -o "$DL_FILE" "$ASSET_URL"
  local got
  got=$(stat -c %s "$DL_FILE")
  if ((ASSET_SIZE > 0 && got != ASSET_SIZE)); then
    msg_error "Download size mismatch: expected ${ASSET_SIZE}, got ${got} bytes."
    exit 1
  fi
  if [[ $ASSET_DIGEST == sha256:* ]]; then
    local sum
    sum=$(sha256sum "$DL_FILE" | awk '{print $1}')
    if [[ $sum != "${ASSET_DIGEST#sha256:}" ]]; then
      msg_error "SHA-256 mismatch (expected ${ASSET_DIGEST#sha256:}, got ${sum})."
      exit 1
    fi
    msg_ok "Download verified (size + SHA-256 from GitHub API)"
  else
    msg_warn "GitHub API gave no SHA-256 digest for this asset: only the size was verified"
  fi
}

extract_loader() { # đặt ARC_IMG
  local out="${TEMP_DIR}/extract" list
  mkdir -p "$out"
  msg_info "Extracting loader image"
  case ${DL_FILE,,} in
    *.zip) silent unzip -tq "$DL_FILE"; silent unzip -oq "$DL_FILE" -d "$out" ;;
    *.gz) gzip -dc "$DL_FILE" >"${out}/arc.img" ;;
    *.img) cp -f "$DL_FILE" "${out}/arc.img" ;;
    *) msg_error "Unsupported loader file type: ${DL_FILE}"; exit 1 ;;
  esac
  list=$(find "$out" -type f -iname '*.img' -printf '%s\t%p\n')
  if [[ -z $list ]]; then
    msg_error "No .img file found after extraction."
    exit 1
  fi
  ARC_IMG=$(sort -rn <<<"$list" | awk -F'\t' 'NR==1{print $2}')
  if (($(stat -c %s "$ARC_IMG") < 16 * 1024 * 1024)); then
    msg_error "Extracted image is suspiciously small: ${ARC_IMG}"
    exit 1
  fi
  # Ảnh đĩa hợp lệ phải có bảng phân vùng đọc được
  if ! sfdisk -d "$ARC_IMG" >/dev/null 2>&1; then
    msg_error "Extracted file has no readable partition table (not a valid disk image)."
    exit 1
  fi
  msg_ok "Loader image ready: $(basename "$ARC_IMG") ($(($(stat -c %s "$ARC_IMG") / 1024 / 1024)) MiB)"
}

# =============================================================================
# Tạo VM
# =============================================================================
size_to_mib() { # "4G" "512M" "2T" -> MiB
  local n=${1%[KMGTkmgt]} u=${1: -1}
  case ${u^^} in
    K) echo $((n / 1024)) ;;
    M) echo "$n" ;;
    G) echo $((n * 1024)) ;;
    T) echo $((n * 1024 * 1024)) ;;
    *) echo 0 ;;
  esac
}

create_vm() {
  # Kiểm tra lần cuối (tránh race) – script KHÔNG BAO GIỜ ghi đè VM có sẵn
  if vmid_in_use "$VMID"; then
    msg_error "VM ID ${VMID} became unavailable. Aborting without touching it."
    exit 1
  fi

  msg_info "Creating VM ${VMID} (${HN})"
  local -a args=(-agent 1 -bios seabios -tablet 0 -ostype l26 -name "$HN"
    -cores "$CORE_COUNT" -sockets 1 -cpu "$CPU_TYPE" -memory "$RAM_SIZE" -balloon 0
    -net0 "${NIC_MODEL},bridge=${BRG},macaddr=${MAC}${VLAN_OPT}"
    -onboot 1 -tags xpenology)
  if [[ $MACHINE_TYPE == q35 ]]; then args+=(-machine q35); fi
  silent qm create "$VMID" "${args[@]}"
  VM_CREATED=1
  msg_ok "VM ${VMID} created"

  # --- Loader: import arc.img → sata0, boot order ---
  msg_info "Importing Arc loader to '${STORAGE}'"
  local -a fmt=()
  if is_file_based "${STG_TYPE[$STORAGE]}"; then fmt=(--format raw); fi
  silent qm importdisk "$VMID" "$ARC_IMG" "$STORAGE" "${fmt[@]}"
  local cfg vol
  cfg=$(qm config "$VMID")
  vol=$(awk -F': ' '/^unused[0-9]+:/{print $2}' <<<"$cfg" | awk 'NR==1')
  if [[ -z $vol ]]; then
    msg_error "Imported loader volume not found in the VM config."
    exit 1
  fi
  silent qm set "$VMID" -sata0 "$vol"
  silent qm set "$VMID" -boot order=sata0
  # README Arc yêu cầu đĩa loader >= 4 GB: nới rộng nếu ảnh nhỏ hơn
  cfg=$(qm config "$VMID")
  if [[ $cfg =~ sata0:[^$'\n']*size=([0-9]+[KMGT]) ]]; then
    if (($(size_to_mib "${BASH_REMATCH[1]}") < LOADER_MIN_GIB * 1024)); then
      silent qm resize "$VMID" sata0 "${LOADER_MIN_GIB}G"
    fi
  else
    msg_warn "Could not read the loader disk size; skipped the ${LOADER_MIN_GIB} GiB resize check"
  fi
  msg_ok "Loader attached as sata0 and set as boot disk"

  # --- Ổ dữ liệu ---
  local kv i=0
  if ((${#SATA_DISKS[@]} > 0)); then
    msg_info "Attaching data disks"
    for kv in "${SATA_DISKS[@]}"; do
      silent qm set "$VMID" "-${kv%%=*}" "${kv#*=}"
    done
    msg_ok "Attached ${#SATA_DISKS[@]} data disk(s)"
  fi
  if ((${#HBA_ADDRS[@]} > 0)); then
    msg_info "Attaching PCI controller(s)"
    local addr opt=""
    [[ $MACHINE_TYPE == q35 ]] && opt=",pcie=1"
    for addr in "${HBA_ADDRS[@]}"; do
      silent qm set "$VMID" "-hostpci${i}" "${addr}${opt}"
      i=$((i + 1))
    done
    msg_ok "Attached ${#HBA_ADDRS[@]} PCI controller(s)"
  fi

  local desc="XPenology DSM 7.2.x (Arc loader ${ARC_TAG})
Created by xpenology-vm.sh v${SCRIPT_VERSION}
Loader disk = sata0 (boot). Configure/build the loader from the VM console."
  silent qm set "$VMID" -description "$desc"
  VM_DONE=1
}

# =============================================================================
# Kết thúc
# =============================================================================
finish() {
  local cfg
  cfg=$(qm config "$VMID")
  echo -e "\n ${BOLD}${DGN}VM configuration${CL}"
  grep -E '^(name|cores|cpu|memory|machine|bios|boot|net0|sata[0-9]|hostpci[0-9]|onboot|agent):' <<<"$cfg" | sed 's/^/   /' || true
  echo
  if confirm "START VM" "VM ${VMID} (${HN}) was created.\n\nStart it now?" 9 60; then
    msg_info "Starting VM ${VMID}"
    if silent qm start "$VMID"; then
      msg_ok "VM ${VMID} started"
    else
      msg_warn "VM ${VMID} was created but could not start (see the message above). Check hostpci/IOMMU settings and 'journalctl -b'."
    fi
  else
    msg_warn "VM not started. Start it with: qm start ${VMID}"
  fi
  cat <<EOF

 ${BOLD}${GN}Next steps${CL}
  1. Open  VM ${VMID} → Console. Arc boots into its config menu.
     (or browse to http://<loader-ip>:7080 — web config; :7681 — web terminal)
  2. In Arc: ${BL}Choose Model → Build Loader → Boot Loader${CL}.
     Before building, check that "Disks (internal)" equals the number of data disks you attached.
  3. After Arc boots DSM, find the installer:
       - https://find.synology.com   or the Synology Assistant, or
       - http://<vm-ip>:5000 (find the IP in your DHCP server / router)
  4. Install DSM (the .pat is downloaded by Arc during the build), then create a storage pool.
  5. Optional: install the QEMU guest agent package in DSM so Proxmox can show the VM IP.

 ${YW}Keep sata0 (the Arc loader disk) as the boot disk — never delete or reorder it.${CL}

EOF
}

# =============================================================================
# main
# =============================================================================
main() {
  header_info
  check_root
  check_tty
  check_pve
  check_arch
  check_kvm
  check_network
  ensure_tools
  load_storages

  start_script
  choose_data_disks

  header_info
  print_summary
  if ! confirm "CREATE VM" "Create the VM with the settings shown in the terminal?\n\nPassthrough disks/controllers selected earlier will be handed to the VM." 11 66; then
    exit_script
  fi

  download_loader
  extract_loader
  create_vm
  msg_ok "Completed successfully"
  finish
}

main "$@"
