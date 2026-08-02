#!/usr/bin/env bash
# Debian 12/13 SSH hardening + Fail2ban + optional Telegram notifications.
set -Eeuo pipefail
IFS=$'\n\t'

readonly APP='vps-security-bootstrap'
readonly SCRIPT_VERSION='v1.3.3'
readonly CONF_DIR='/etc/vps-security'
readonly SSH_DROPIN='/etc/ssh/sshd_config.d/00-vps-security-bootstrap.conf'
readonly LEGACY_SSH_DROPIN='/etc/ssh/sshd_config.d/99-vps-security-bootstrap.conf'
readonly F2B_JAIL='/etc/fail2ban/jail.d/sshd-vps-security.local'
readonly F2B_ACTION='/etc/fail2ban/action.d/vps-security-telegram.conf'
readonly F2B_RECIDIVE_JAIL='/etc/fail2ban/jail.d/recidive-vps-security.local'
readonly F2B_LOG_LOCAL='/etc/fail2ban/fail2ban.d/00-vps-security-bootstrap.local'
readonly NOTIFIER='/usr/local/sbin/vps-security-notify'
readonly LEGACY_TELEGRAM_CONTROL='/usr/local/sbin/vps-security-telegram-control'
readonly LEGACY_TELEGRAM_CONTROL_SERVICE='/etc/systemd/system/vps-security-telegram-control.service'
readonly AUTO_UPGRADES_CONF='/etc/apt/apt.conf.d/52-vps-security-bootstrap-auto-upgrades'
readonly FIREWALL_TABLE='vps_security_bootstrap'
readonly FIREWALL_CONFIG="$CONF_DIR/nftables.conf"
readonly FIREWALL_TCP_PORTS_FILE="$CONF_DIR/firewall-tcp-ports"
readonly FIREWALL_UDP_PORTS_FILE="$CONF_DIR/firewall-udp-ports"
readonly FIREWALL_LOADER='/usr/local/sbin/vps-security-load-firewall'
readonly NFTABLES_DROPIN_DIR='/etc/systemd/system/nftables.service.d'
readonly NFTABLES_DROPIN="$NFTABLES_DROPIN_DIR/20-vps-security-bootstrap.conf"
SSH_PORT=52022
PUBLIC_KEY=''
PUBLIC_KEY_FILE=''
IGNORE_IP=''
TELEGRAM_TOKEN=''
TELEGRAM_CHAT_ID=''
TELEGRAM_TOKEN_FILE=''
TELEGRAM_CHAT_ID_FILE=''
TELEGRAM_VPS_NAME=''
BANTIME=1d
SYSTEM_UPGRADE=0
SYSTEM_UPGRADE_OPTION=''
INTERACTIVE=0
INTERACTIVE_FLAG=0
ROTATE_TELEGRAM=0
FIREWALL_ONLY=0
FAIL2BAN_MUTATION_ACTIVE=0
FAIL2BAN_WAS_ACTIVE=0
FAIL2BAN_WAS_ENABLED=0
NFTABLES_WAS_ACTIVE=0
NFTABLES_WAS_ENABLED=0
ORIGINAL_ARGC=$#

if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
  STYLE_RESET=$'\033[0m'
  STYLE_TITLE=$'\033[1;33m'
  STYLE_MENU=$'\033[1;33m'
  STYLE_PROMPT=$'\033[1;33m'
  STYLE_INFO=$'\033[1;33m'
  STYLE_SUCCESS=$'\033[1;32m'
  STYLE_ERROR=$'\033[1;31m'
  STYLE_DIM=$'\033[2m'
else
  STYLE_RESET=''
  STYLE_TITLE=''
  STYLE_MENU=''
  STYLE_PROMPT=''
  STYLE_INFO=''
  STYLE_SUCCESS=''
  STYLE_ERROR=''
  STYLE_DIM=''
fi

usage() {
  cat <<'EOF'

普通用法（推荐，逐项填写）：
  sudo bash bootstrap.sh

仅更换 Telegram Bot Token（不修改 SSH、公钥或 Fail2ban 策略）：
  sudo bash bootstrap.sh --rotate-telegram-token

管理脚本专用的 nftables 防火墙规则（不修改 SSH 或公钥）：
  sudo bash bootstrap.sh --firewall

自动化用法（传入参数，不进入向导）：
EOF
  cat <<'EOF'
用法：
  sudo bash bootstrap.sh --public-key-file /path/to/id_ed25519.pub [选项]

必填（二选一）：
  --public-key-file PATH       root 的 SSH 公钥文件
  --public-key 'ssh-ed25519 …' root 的 SSH 公钥文本

选项：
  --interactive                强制进入交互式向导（不可与其他参数同时使用）
  --ssh-port PORT              SSH 端口；参数模式默认：52022
  --ignoreip CIDR[,CIDR...]    Fail2ban 永不封禁的可信 IP/CIDR（可选）
  --telegram-token-file PATH   从 root 可读文件读取 token（推荐，避免出现在历史记录）
  --telegram-chat-id-file PATH 从 root 可读文件读取 chat id（推荐）
  --telegram-vps-name NAME     Telegram 中显示的 VPS 名称（默认：主机名）
  --permanent-bans             SSH jail 永久封禁（默认逐级延长至 4 周）
  --system-upgrade             执行一次 apt upgrade（参数模式默认跳过）
  --skip-system-upgrade        跳过 apt upgrade（兼容旧用法；仍会 apt update 并安装依赖）
  --rotate-telegram-token      交互式更换 Telegram Token，不修改 SSH 或 Fail2ban 策略
  --firewall                   交互式管理 nftables 放行端口和查看规则
  -h, --help                   显示本帮助
EOF
}
die() { printf '%b错误：%s%b\n' "$STYLE_ERROR" "$*" "$STYLE_RESET" >&2; exit 1; }
info() { printf '\n%b==> %s%b\n' "$STYLE_INFO" "$*" "$STYLE_RESET"; }
success() { printf '%b完成：%s%b\n' "$STYLE_SUCCESS" "$*" "$STYLE_RESET"; }
need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    die "$1 需要一个值"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --interactive) INTERACTIVE=1; INTERACTIVE_FLAG=1; shift ;;
    --public-key-file) need_value "$@"; PUBLIC_KEY_FILE=$2; shift 2 ;;
    --public-key) need_value "$@"; PUBLIC_KEY=$2; shift 2 ;;
    --ssh-port) need_value "$@"; SSH_PORT=$2; shift 2 ;;
    --ignoreip) need_value "$@"; IGNORE_IP=$2; shift 2 ;;
    --telegram-token|--telegram-chat-id)
      die '为避免 token 泄露到 shell 历史或进程参数，请使用 --telegram-token-file 和 --telegram-chat-id-file。'
      ;;
    --telegram-token-file) need_value "$@"; TELEGRAM_TOKEN_FILE=$2; shift 2 ;;
    --telegram-chat-id-file) need_value "$@"; TELEGRAM_CHAT_ID_FILE=$2; shift 2 ;;
    --telegram-vps-name) need_value "$@"; TELEGRAM_VPS_NAME=$2; shift 2 ;;
    --permanent-bans) BANTIME=-1; shift ;;
    --system-upgrade)
      [ -z "$SYSTEM_UPGRADE_OPTION" ] || die '--system-upgrade 与 --skip-system-upgrade 不能同时使用。'
      SYSTEM_UPGRADE=1
      SYSTEM_UPGRADE_OPTION=upgrade
      shift
      ;;
    --skip-system-upgrade)
      [ -z "$SYSTEM_UPGRADE_OPTION" ] || die '--system-upgrade 与 --skip-system-upgrade 不能同时使用。'
      SYSTEM_UPGRADE=0
      SYSTEM_UPGRADE_OPTION=skip
      shift
      ;;
    --rotate-telegram-token) ROTATE_TELEGRAM=1; INTERACTIVE=1; INTERACTIVE_FLAG=1; shift ;;
    --firewall) FIREWALL_ONLY=1; INTERACTIVE=1; INTERACTIVE_FLAG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done

[ "$ORIGINAL_ARGC" -eq 0 ] && INTERACTIVE=1
[ "$INTERACTIVE_FLAG" -eq 0 ] || [ "$ORIGINAL_ARGC" -eq 1 ] || die '--interactive 不能与其他参数同时使用。'

prompt_default() {
  local variable=$1 prompt=$2 default=$3 value default_label
  default_label=${default:-留空}
  if ! read -r -p "${STYLE_PROMPT}${prompt} [默认：${default_label}，回车采用默认]：${STYLE_RESET}" value; then
    die '未读取到输入，操作已取消。'
  fi
  printf -v "$variable" '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt=$1 default=${2:-n} answer
  while true; do
    if [ "$default" = y ]; then
      if ! read -r -p "${STYLE_PROMPT}${prompt} [Y/n，回车=是]：${STYLE_RESET}" answer; then
        die '未读取到输入，操作已取消。'
      fi
      answer=${answer:-y}
    else
      if ! read -r -p "${STYLE_PROMPT}${prompt} [y/N，回车=否]：${STYLE_RESET}" answer; then
        die '未读取到输入，操作已取消。'
      fi
      answer=${answer:-n}
    fi
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf '%b请输入 y 或 n；也可以直接按回车采用默认值。%b\n' "$STYLE_ERROR" "$STYLE_RESET" ;;
    esac
  done
}

prompt_line() {
  printf '%b%s%b\n' "$STYLE_PROMPT" "$*" "$STYLE_RESET"
}

discard_pasted_empty_lines() {
  local buffered
  while IFS= read -r -t 0.05 buffered; do
    buffered=${buffered%$'\r'}
    if [ -n "$buffered" ]; then
      break
    fi
  done
  return 0
}

prompt_block() {
  printf '%b' "$STYLE_PROMPT"
  cat
  printf '%b' "$STYLE_RESET"
}

menu_option() {
  local number=$1 title=$2 description=${3:-}
  printf '  %b%s. %s' "$STYLE_MENU" "$number" "$title"
  [ -z "$description" ] || printf '%b %b· %s' "$STYLE_RESET" "$STYLE_DIM" "$description"
  printf '%b\n' "$STYLE_RESET"
}

print_banner() {
  local -a logo=(
    '██████╗ ██╗██╗  ██╗ █████╗  ██████╗██╗  ██╗██╗   ██╗'
    '██╔══██╗██║██║ ██╔╝██╔══██╗██╔════╝██║  ██║██║   ██║'
    '██████╔╝██║█████╔╝ ███████║██║     ███████║██║   ██║'
    '██╔═══╝ ██║██╔═██╗ ██╔══██║██║     ██╔══██║██║   ██║'
    '██║     ██║██║  ██╗██║  ██║╚██████╗██║  ██║╚██████╔╝'
    '╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝'
  )
  local line
  for line in "${logo[@]}"; do
    printf '%b%s%b\n' "$STYLE_TITLE" "$line" "$STYLE_RESET"
  done
  printf '%bVPS SECURITY BOOTSTRAP %s · DEBIAN 12 / 13%b\n' "$STYLE_TITLE" "$SCRIPT_VERSION" "$STYLE_RESET"
}

detect_current_ssh_port() {
  if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    # 不让 awk 提前退出；配合 pipefail 时，提前退出可能让 sshd 收到 SIGPIPE，
    # 从而被 set -e 误判为检测端口失败。
    sshd -T | awk '$1 == "port" && !found { print $2; found = 1 } END { exit !found }'
  else
    printf '22'
  fi
}

normalize_port_specs() {
  local raw=${1:-}
  python3 - "$raw" <<'PY'
import sys

raw = sys.argv[1].strip()
if not raw:
    print('')
    raise SystemExit(0)

ranges = []
for item in raw.split(','):
    item = item.strip()
    if not item:
        raise ValueError('不能包含空端口项')
    pieces = item.split('-', 1)
    if len(pieces) == 1:
        if not pieces[0].isdigit():
            raise ValueError(f'端口格式无效：{item}')
        start = end = int(pieces[0])
    else:
        if not pieces[0].isdigit() or not pieces[1].isdigit():
            raise ValueError(f'端口范围格式无效：{item}')
        start, end = map(int, pieces)
    if not (1 <= start <= end <= 65535):
        raise ValueError(f'端口必须在 1-65535，且范围起点不得大于终点：{item}')
    ranges.append((start, end))

merged = []
for start, end in sorted(ranges):
    if merged and start <= merged[-1][1] + 1:
        merged[-1] = (merged[-1][0], max(merged[-1][1], end))
    else:
        merged.append((start, end))
print(','.join(str(start) if start == end else f'{start}-{end}' for start, end in merged))
PY
}

load_firewall_port_state() {
  local file=$1 value=''
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || die "防火墙端口状态文件必须是普通文件：$file"
    value=$(head -n 1 "$file")
  fi
  normalize_port_specs "$value" || die "防火墙端口状态文件无效：$file"
}

port_specs_to_nft_elements() {
  local specs=$1
  [ -n "$specs" ] || return 0
  printf '%s' "${specs//,/, }"
}

render_firewall_config() {
  local output=$1 ssh_ports=$2 extra_tcp=$3 extra_udp=$4 all_tcp all_udp tcp_elements udp_elements
  all_tcp=$(normalize_port_specs "$ssh_ports${extra_tcp:+,$extra_tcp}") || return 1
  all_udp=$(normalize_port_specs "$extra_udp") || return 1
  tcp_elements=$(port_specs_to_nft_elements "$all_tcp")
  udp_elements=$(port_specs_to_nft_elements "$all_udp")

  {
    cat <<EOF
# Managed by $APP. Use the nftables firewall menu in bootstrap.sh to change ports.
# This file owns only table inet $FIREWALL_TABLE; it never flushes the global ruleset.
table inet $FIREWALL_TABLE {
  set allowed_tcp_ports {
    type inet_service
    flags interval
    elements = { $tcp_elements }
  }

  set allowed_udp_ports {
    type inet_service
    flags interval
EOF
    if [ -n "$udp_elements" ]; then
      printf '    elements = { %s }\n' "$udp_elements"
    fi
    cat <<'EOF'
  }

  chain input {
    type filter hook input priority filter; policy drop;
    ct state invalid drop
    ct state established,related accept
    iifname "lo" accept
    ip protocol icmp accept
    meta l4proto icmpv6 accept
    tcp dport @allowed_tcp_ports accept
    udp dport @allowed_udp_ports accept
  }
}
EOF
  } > "$output"
}

restore_firewall_files() {
  local backup_dir=$1 target backup
  for target in "$FIREWALL_CONFIG" "$FIREWALL_TCP_PORTS_FILE" "$FIREWALL_UDP_PORTS_FILE" "$FIREWALL_LOADER" "$NFTABLES_DROPIN"; do
    backup="$backup_dir/$(basename "$target")"
    if [ -e "$backup" ]; then
      install -d -m 0755 "$(dirname "$target")"
      cp -a "$backup" "$target"
    else
      rm -f "$target"
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
}

apply_firewall_policy() {
  local ssh_ports=$1 extra_tcp=$2 extra_udp=$3
  local config_tmp tcp_tmp udp_tmp loader_tmp validation_tmp backup_dir target nft_bin
  local -a targets

  command -v python3 >/dev/null 2>&1 || {
    printf '未找到 python3，无法校验端口范围。\n' >&2
    return 1
  }
  command -v nft >/dev/null 2>&1 || {
    printf '未找到 nft，无法配置防火墙。\n' >&2
    return 1
  }
  systemctl cat nftables.service >/dev/null 2>&1 || {
    printf '未找到 nftables.service，无法持久化防火墙。\n' >&2
    return 1
  }

  extra_tcp=$(normalize_port_specs "$extra_tcp") || return 1
  extra_udp=$(normalize_port_specs "$extra_udp") || return 1
  install -d -o root -g root -m 0700 "$CONF_DIR"
  install -d -o root -g root -m 0755 "$NFTABLES_DROPIN_DIR"
  config_tmp=$(mktemp "$CONF_DIR/nftables.conf.XXXXXX") || return 1
  tcp_tmp=$(mktemp "$CONF_DIR/firewall-tcp-ports.XXXXXX") || { rm -f "$config_tmp"; return 1; }
  udp_tmp=$(mktemp "$CONF_DIR/firewall-udp-ports.XXXXXX") || { rm -f "$config_tmp" "$tcp_tmp"; return 1; }
  loader_tmp=$(mktemp "$CONF_DIR/nftables-loader.XXXXXX") || { rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp"; return 1; }
  validation_tmp=$(mktemp "$CONF_DIR/nftables-validation.XXXXXX") || { rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp"; return 1; }
  backup_dir=$(mktemp -d "$CONF_DIR/firewall-rollback.XXXXXX") || {
    rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp" "$validation_tmp"
    return 1
  }

  if ! render_firewall_config "$config_tmp" "$ssh_ports" "$extra_tcp" "$extra_udp"; then
    rm -rf -- "$backup_dir"
    rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp" "$validation_tmp"
    return 1
  fi
  printf '%s\n' "$extra_tcp" > "$tcp_tmp"
  printf '%s\n' "$extra_udp" > "$udp_tmp"
  chmod 0644 "$config_tmp"
  chmod 0600 "$tcp_tmp" "$udp_tmp"

  # Validate against a throwaway table name so a currently loaded managed table cannot mask syntax errors.
  sed "s/$FIREWALL_TABLE/${FIREWALL_TABLE}_validation_$$/g" "$config_tmp" > "$validation_tmp"
  if ! nft -c -f "$validation_tmp"; then
    rm -rf -- "$backup_dir"
    rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp" "$validation_tmp"
    return 1
  fi
  rm -f "$validation_tmp"

  targets=("$FIREWALL_CONFIG" "$FIREWALL_TCP_PORTS_FILE" "$FIREWALL_UDP_PORTS_FILE" "$FIREWALL_LOADER" "$NFTABLES_DROPIN")
  for target in "${targets[@]}"; do
    if [ -e "$target" ]; then
      cp -a "$target" "$backup_dir/$(basename "$target")" || {
        rm -rf -- "$backup_dir"
        rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp"
        return 1
      }
    fi
  done

  nft_bin=$(command -v nft)
  cat > "$loader_tmp" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
"$nft_bin" delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
exec "$nft_bin" -f "$FIREWALL_CONFIG"
EOF
  chmod 0700 "$loader_tmp"
  if ! mv -f "$config_tmp" "$FIREWALL_CONFIG" ||
    ! mv -f "$tcp_tmp" "$FIREWALL_TCP_PORTS_FILE" ||
    ! mv -f "$udp_tmp" "$FIREWALL_UDP_PORTS_FILE" ||
    ! mv -f "$loader_tmp" "$FIREWALL_LOADER" ||
    ! printf '[Service]\nExecStartPost=%s\n' "$FIREWALL_LOADER" > "$NFTABLES_DROPIN" ||
    ! systemctl daemon-reload ||
    ! systemctl enable nftables; then
    restore_firewall_files "$backup_dir"
    rm -rf -- "$backup_dir"
    rm -f "$config_tmp" "$tcp_tmp" "$udp_tmp" "$loader_tmp"
    return 1
  fi

  # Only the table owned by this script is replaced. Fail2ban and other applications keep their own tables.
  if systemctl is-active --quiet nftables; then
    if ! "$FIREWALL_LOADER"; then
      restore_firewall_files "$backup_dir"
      nft delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
      [ ! -f "$FIREWALL_LOADER" ] || "$FIREWALL_LOADER" 2>/dev/null || true
      rm -rf -- "$backup_dir"
      return 1
    fi
  elif ! systemctl start nftables; then
    restore_firewall_files "$backup_dir"
    nft delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
    [ ! -f "$FIREWALL_LOADER" ] || "$FIREWALL_LOADER" 2>/dev/null || true
    rm -rf -- "$backup_dir"
    return 1
  fi

  if ! nft list table inet "$FIREWALL_TABLE" >/dev/null; then
    restore_firewall_files "$backup_dir"
    nft delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
    [ ! -f "$FIREWALL_LOADER" ] || "$FIREWALL_LOADER" 2>/dev/null || true
    rm -rf -- "$backup_dir"
    return 1
  fi
  rm -rf -- "$backup_dir"
}

configure_nftables_firewall() {
  local ssh_ports=$1 extra_tcp extra_udp
  extra_tcp=$(load_firewall_port_state "$FIREWALL_TCP_PORTS_FILE")
  extra_udp=$(load_firewall_port_state "$FIREWALL_UDP_PORTS_FILE")
  apply_firewall_policy "$ssh_ports" "$extra_tcp" "$extra_udp"
}

show_firewall_status() {
  local ssh_port extra_tcp extra_udp managed_status table_status managed_enabled=0
  ssh_port=$(detect_current_ssh_port)
  extra_tcp=$(load_firewall_port_state "$FIREWALL_TCP_PORTS_FILE")
  extra_udp=$(load_firewall_port_state "$FIREWALL_UDP_PORTS_FILE")
  if [ -x "$FIREWALL_LOADER" ] && [ -f "$NFTABLES_DROPIN" ]; then
    managed_enabled=1
    managed_status='已启用（开机自动加载）'
  else
    managed_status='已停用（保留端口设置，未加载默认拒绝规则）'
  fi
  if nft list table inet "$FIREWALL_TABLE" >/dev/null 2>&1; then
    table_status='已加载'
  else
    table_status='未加载'
  fi
  printf '\n%b当前脚本管理的 nftables 防火墙：%b\n' "$STYLE_TITLE" "$STYLE_RESET"
  printf '  本脚本防火墙：%s；规则表：%s\n' "$managed_status" "$table_status"
  if [ "$managed_enabled" -eq 1 ]; then
    printf '  入站默认策略：拒绝（仅以下端口放行）\n'
  else
    printf '  入站默认策略：未由本脚本限制\n'
  fi
  printf '  SSH TCP：%s\n' "$ssh_port"
  printf '  额外 TCP：%s\n' "${extra_tcp:-无}"
  printf '  额外 UDP：%s\n' "${extra_udp:-无}"
  printf '  nftables 服务：%s / 开机启动：%s\n' \
    "$(systemctl is-active nftables 2>/dev/null || true)" \
    "$(systemctl is-enabled nftables 2>/dev/null || true)"
  if nft list table inet "$FIREWALL_TABLE" >/dev/null 2>&1; then
    printf '\n%b实际生效规则：%b\n' "$STYLE_INFO" "$STYLE_RESET"
    nft list table inet "$FIREWALL_TABLE"
  else
    printf '%b本脚本管理的防火墙当前未加载；选择“启用 / 恢复为仅放行 SSH”即可启用。%b\n' "$STYLE_ERROR" "$STYLE_RESET"
  fi
}

disable_managed_firewall() {
  local dropin_backup
  [ -d "$CONF_DIR" ] || return 0
  dropin_backup=$(mktemp "$CONF_DIR/nftables-dropin-disable.XXXXXX") || return 1
  if [ -f "$NFTABLES_DROPIN" ]; then
    cp -a "$NFTABLES_DROPIN" "$dropin_backup" || {
      rm -f "$dropin_backup"
      return 1
    }
  else
    : > "$dropin_backup"
  fi
  if ! rm -f "$NFTABLES_DROPIN" || ! systemctl daemon-reload; then
    if [ -s "$dropin_backup" ]; then
      install -d -m 0755 "$NFTABLES_DROPIN_DIR"
      cp -a "$dropin_backup" "$NFTABLES_DROPIN"
    fi
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$dropin_backup"
    return 1
  fi
  rm -f "$dropin_backup"
  nft delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
}

enable_managed_firewall() {
  local ssh_port current_tcp current_udp
  ssh_port=$(detect_current_ssh_port)
  current_tcp=$(load_firewall_port_state "$FIREWALL_TCP_PORTS_FILE")
  current_udp=$(load_firewall_port_state "$FIREWALL_UDP_PORTS_FILE")
  apply_firewall_policy "$ssh_port" "$current_tcp" "$current_udp"
}

reload_managed_firewall() {
  [ -x "$FIREWALL_LOADER" ] && [ -f "$NFTABLES_DROPIN" ] || {
    printf '本脚本管理的防火墙当前未启用；请先选择“启用本脚本管理的防火墙”。\n' >&2
    return 1
  }
  enable_managed_firewall
}

prompt_firewall_ports() {
  local protocol=$1 current=$2 updated
  prompt_block <<EOF
${protocol} 端口格式：单端口、范围，或逗号组合。
示例：80,443,51820,20000-20199
直接回车 = 不额外放行任何 ${protocol} 端口（会清空当前 ${protocol} 额外规则）。
EOF
  if ! read -r -p "${STYLE_PROMPT}新的额外 ${protocol} 端口 [当前：${current:-无}]：${STYLE_RESET}" updated; then
    die '未读取到端口输入，操作已取消。'
  fi
  normalize_port_specs "$updated" || die '端口格式无效；请使用 1-65535 的端口或端口范围。'
}

firewall_menu() {
  local choice current_tcp current_udp new_ports ssh_port
  [ -t 0 ] || die 'nftables 防火墙菜单需要交互式终端。'
  info '检查 nftables 与端口校验依赖'
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=60 update
  apt-get -o DPkg::Lock::Timeout=60 install -y nftables python3-minimal
  while true; do
    current_tcp=$(load_firewall_port_state "$FIREWALL_TCP_PORTS_FILE")
    current_udp=$(load_firewall_port_state "$FIREWALL_UDP_PORTS_FILE")
    printf '\n%b请选择 nftables 防火墙操作：%b\n' "$STYLE_MENU" "$STYLE_RESET"
    menu_option 1 '查看放行端口和实际生效规则'
    menu_option 2 '设置额外 TCP 放行端口' "当前：${current_tcp:-无}"
    menu_option 3 '设置额外 UDP 放行端口' "当前：${current_udp:-无}"
    menu_option 4 '启用本脚本管理的防火墙' '保留已设置的 TCP/UDP 端口，并开启默认拒绝入站'
    menu_option 5 '恢复为仅放行 SSH 端口' '清空所有额外 TCP/UDP 端口，并开启默认拒绝入站'
    menu_option 6 '停用本脚本管理的防火墙' '仅移除本脚本的默认拒绝规则；不停止 nftables 服务或修改其他规则'
    menu_option 7 '重新加载本脚本管理的防火墙' '仅校验并重载本脚本的规则表；不重启 nftables 服务'
    menu_option 0 '返回主菜单'
    if ! read -r -p "${STYLE_MENU}请选择 [1/2/3/4/5/6/7/0，无默认值]：${STYLE_RESET}" choice; then
      die '未读取到菜单选项，操作已取消。'
    fi
    ssh_port=$(detect_current_ssh_port)
    case "$choice" in
      1) show_firewall_status ;;
      2)
        new_ports=$(prompt_firewall_ports TCP "$current_tcp")
        ask_yes_no "确认更新额外 TCP 端口为：${new_ports:-无}？" n || continue
        apply_firewall_policy "$ssh_port" "$new_ports" "$current_udp" || die '更新 nftables TCP 规则失败；已尝试恢复原有配置。'
        success 'nftables TCP 放行端口已更新。'
        ;;
      3)
        new_ports=$(prompt_firewall_ports UDP "$current_udp")
        ask_yes_no "确认更新额外 UDP 端口为：${new_ports:-无}？" n || continue
        apply_firewall_policy "$ssh_port" "$current_tcp" "$new_ports" || die '更新 nftables UDP 规则失败；已尝试恢复原有配置。'
        success 'nftables UDP 放行端口已更新。'
        ;;
      4)
        ask_yes_no '确认启用本脚本管理的默认拒绝规则，并保留当前端口设置？' n || continue
        enable_managed_firewall || die '启用本脚本管理的防火墙失败；已尝试恢复原有配置。'
        success '本脚本管理的防火墙已启用，并已保留当前端口设置。'
        ;;
      5)
        ask_yes_no '确认清空所有额外端口，并启用仅放行 SSH 的默认拒绝入站规则？' n || continue
        apply_firewall_policy "$ssh_port" '' '' || die '启用仅 SSH 防火墙失败；已尝试恢复原有配置。'
        success "防火墙已启用：仅放行 SSH TCP $ssh_port。"
        ;;
      6)
        ask_yes_no '确认停用本脚本管理的默认拒绝规则？SSH 和其他服务将不再由本脚本的主机防火墙限制。' n || continue
        disable_managed_firewall || die '停用本脚本管理的防火墙失败；原有规则已尽力保留。'
        success '本脚本管理的防火墙已停用；nftables 服务、Fail2ban 和其他应用规则未被停止或删除。'
        ;;
      7)
        ask_yes_no '确认重新加载本脚本管理的防火墙规则？' n || continue
        reload_managed_firewall || die '重新加载本脚本管理的防火墙失败；请查看状态和实际规则。'
        success '本脚本管理的防火墙规则已重新加载。'
        ;;
      0) return 0 ;;
      *) printf '%b请输入 1、2、3、4、5、6、7 或 0。%b\n' "$STYLE_ERROR" "$STYLE_RESET" ;;
    esac
  done
}

prompt_for_public_key() {
  while true; do
    if ! read -r -p "${STYLE_PROMPT}root SSH 公钥：${STYLE_RESET}" PUBLIC_KEY; then
      die '无法读取 SSH 公钥输入；请确认是在交互式终端中运行脚本。'
    fi
    PUBLIC_KEY=${PUBLIC_KEY%$'\r'}
    if [ -n "$PUBLIC_KEY" ]; then
      discard_pasted_empty_lines
      prompt_line '已接收 SSH 公钥，继续设置 SSH 端口。'
      return 0
    fi
    prompt_line '错误：SSH 公钥不能为空；请粘贴 .pub 文件中的完整一行内容后按回车。'
  done
}

interactive_wizard() {
  local current_port answer
  [ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh'
  [ -t 0 ] || die '交互式向导需要终端；自动化运行请传入 --public-key-file 等参数。'
  clear 2>/dev/null || true
  print_banner
  if [ "$ROTATE_TELEGRAM" -eq 0 ] && [ "$FIREWALL_ONLY" -eq 0 ]; then
    printf '%b请选择操作：%b\n' "$STYLE_MENU" "$STYLE_RESET"
    menu_option 1 '初次部署 / 重新加固 SSH' '覆盖 root 公钥，更新 SSH / Fail2ban，并启用本脚本防火墙'
    menu_option 2 '更换 Telegram Bot Token' '不修改 SSH、公钥、端口或 Fail2ban'
    menu_option 3 'nftables 防火墙操作' '查看、管理、启用、停用或重载本脚本的防火墙规则'
    menu_option 0 '退出，不做任何修改'
    while true; do
      if ! read -r -p "${STYLE_MENU}请选择 [1/2/3/0，无默认值]：${STYLE_RESET}" answer; then
        die '未读取到菜单选项，操作已取消。'
      fi
      case "$answer" in
        1) break ;;
        2) ROTATE_TELEGRAM=1; break ;;
        3) FIREWALL_ONLY=1; break ;;
        0) exit 0 ;;
        *) printf '%b请输入 1、2、3 或 0。%b\n' "$STYLE_ERROR" "$STYLE_RESET" ;;
      esac
    done
  fi
  [ "$ROTATE_TELEGRAM" -eq 0 ] || return 0
  [ "$FIREWALL_ONLY" -eq 0 ] || return 0
  prompt_block <<'EOF'
注意：
  1. 只保留 root 作为 SSH 用户，并且只允许本次提供的 SSH 公钥登录。
  2. SSH 密码登录会关闭，同时启用 Fail2ban 和可选的 Telegram 通知。
  3. 向导会先收集你的选择；只有最后确认后才会开始修改系统。
  4. 请保持当前 SSH 窗口打开，直到新的 SSH 连接验证成功。
  5. 请从你自己的电脑复制 SSH 公钥 .pub 文件的完整一行内容，再粘贴到下方。
  6. 公钥文件通常位于：
     Linux/macOS：~/.ssh/id_ed25519.pub
     Windows PowerShell：Get-Content $HOME\.ssh\id_ed25519.pub
  7. 只能粘贴 .pub 公钥，绝不能粘贴 id_ed25519 等没有 .pub 后缀的私钥文件。
     示例：ssh-ed25519 AAAA... your-computer
EOF
  prompt_for_public_key
  current_port=$(detect_current_ssh_port)
  prompt_default SSH_PORT '新的 SSH 端口（直接回车保留当前端口；改端口前须放行云安全组）' "$current_port"
  if [ "$SSH_PORT" != "$current_port" ]; then
    prompt_block <<EOF
注意：
  1. SSH 端口将从 $current_port 改为 $SSH_PORT。
  2. 脚本会先同时放行旧端口和新端口；SSH 重载成功后，旧端口将拒绝新的连接。
  3. 当前已建立的 SSH 会话会继续可用，但关闭或断开后不能再通过旧端口重连。
  4. 请先在云厂商安全组/防火墙中放行新端口，并在退出当前窗口前另开终端测试新端口。
EOF
    ask_yes_no '已确认新端口已放行吗？' n || die '已取消；请先放行新端口后再运行。'
  fi
  prompt_default IGNORE_IP 'Fail2ban 白名单 IP/CIDR（直接回车：不添加公网白名单）' ''
  prompt_line '提示：正确的 SSH 私钥登录无需加入白名单；所有选择会在最后确认后才开始执行。'
  if ask_yes_no '执行 apt upgrade，安装全部可用更新？（安装依赖仍会执行 apt update）' n; then SYSTEM_UPGRADE=1; else SYSTEM_UPGRADE=0; fi
  if ask_yes_no '启用 Telegram 登录/封禁通知？' n; then
    prompt_block <<'EOF'
Telegram 配置：
  1. 在 Telegram 搜索 @BotFather，发送 /newbot 并按提示创建机器人。
  2. 复制 BotFather 返回的 HTTP API Token；该 Token 相当于机器人密码，不要发送给他人。
  3. 打开你创建的机器人，点击 Start 并发送任意一条消息。
  4. 在可信设备的浏览器访问：
     https://api.telegram.org/bot<你的Token>/getUpdates
     在返回内容中找到 message.chat.id，并复制对应的数字作为 Chat ID。
EOF
    prompt_line '提示：粘贴 Bot Token 后屏幕不会显示字符、星号或长度；这是正常保护，直接按回车即可。'
    if ! read -rsp "${STYLE_PROMPT}Telegram Bot Token（必填；输入不回显，粘贴后按回车）：${STYLE_RESET}" TELEGRAM_TOKEN; then
      die '未读取到 Telegram Bot Token，操作已取消。'
    fi
    printf '\n'
    if ! read -r -p "${STYLE_PROMPT}Telegram Chat ID（必填，仅数字）：${STYLE_RESET}" TELEGRAM_CHAT_ID; then
      die '未读取到 Telegram Chat ID，操作已取消。'
    fi
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
      die 'Telegram Token 和 Chat ID 都不能为空。'
    fi
    prompt_default TELEGRAM_VPS_NAME 'Telegram 中显示的 VPS 名称' "$(hostname -f 2>/dev/null || hostname)"
  fi
  prompt_block <<EOF
配置摘要：
  1. SSH 用户：root（仅本次提供的 SSH 公钥登录；旧公钥将失效）
  2. SSH 端口：$SSH_PORT
  3. Fail2ban 白名单：${IGNORE_IP:-未设置（不额外白名单公网 IP）}
  4. Fail2ban 策略：3 分钟内 SSH 失败 3 次即封禁；反复封禁来源将永久封禁全部端口
  5. 系统立即升级：$([ "$SYSTEM_UPGRADE" -eq 1 ] && echo 是 || echo 否)
  6. Telegram 通知：$([ -n "$TELEGRAM_TOKEN" ] && echo 是 || echo 否)
  7. nftables：启用默认拒绝入站；放行 SSH，并保留已配置的额外端口（如有）
EOF
  [ -z "$TELEGRAM_TOKEN" ] || prompt_line "  Telegram 名称：${TELEGRAM_VPS_NAME:-$(hostname)}"
  ask_yes_no '确认执行以上配置？' n || die '已取消，未修改系统。'
}

[ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh …'
[ -r /etc/debian_version ] || die '此脚本仅面向 Debian 12 或 13。'
# Debian guarantees this system metadata file.
# shellcheck disable=SC1091
. /etc/os-release
[ "$ID" = debian ] || die '此脚本仅支持 Debian。'
case "${VERSION_ID%%.*}" in
  12|13) ;;
  *) die '此脚本仅支持 Debian 12 或 13。' ;;
esac
[ -d /run/systemd/system ] || die '此脚本需要 systemd。'
[ "$INTERACTIVE" -eq 0 ] || interactive_wizard
[ "$FIREWALL_ONLY" -eq 0 ] || {
  firewall_menu
  exit 0
}
if ! [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$SSH_PORT" -gt 65535 ]; then
  die '--ssh-port 必须是 1–65535。'
fi
[ -z "$PUBLIC_KEY" ] || [ -z "$PUBLIC_KEY_FILE" ] || die '只能使用一种公钥传入方式。'
require_root_private_file() {
  local path=$1 label=$2 owner mode
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    die "无法读取 $label 文件：$path"
  fi
  owner=$(stat -c '%u' "$path")
  mode=$(stat -c '%a' "$path")
  [ "$owner" -eq 0 ] || die "$label 文件必须由 root 所有：$path"
  (( (8#$mode & 077) == 0 )) || die "$label 文件权限必须是 0600 或更严格：$path"
}

validate_telegram_settings() {
  if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    die 'Telegram Token 和 Chat ID 都不能为空。'
  fi
  [[ "$TELEGRAM_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || \
    die 'Telegram Token 格式无效；请粘贴 BotFather 返回的完整 Token。'
  [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]] || die 'Telegram Chat ID 必须是数字；群组 Chat ID 可以是负数。'
  [ -z "$TELEGRAM_VPS_NAME" ] || [[ "$TELEGRAM_VPS_NAME" != *$'\n'* && "$TELEGRAM_VPS_NAME" != *$'\r'* && ${#TELEGRAM_VPS_NAME} -le 80 ]] || die 'Telegram VPS 名称不能包含换行，且最多 80 个字符。'
}

write_telegram_env() {
  local temporary
  install -d -o root -g root -m 0700 "$CONF_DIR"
  temporary=$(mktemp "$CONF_DIR/telegram.env.XXXXXX") || die '无法创建 Telegram 临时配置文件。'
  printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\nTELEGRAM_VPS_NAME=%q\n' \
    "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT_ID" "$TELEGRAM_VPS_NAME" > "$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$CONF_DIR/telegram.env"
}

send_telegram_rotation_test() {
  local host now text
  host=$(hostname -f 2>/dev/null || hostname)
  now=$(date -u -d '+8 hours' '+%Y-%m-%d %H:%M:%S 北京时间 (UTC+8)')
  printf -v text '✅ Telegram Token 已更新\nVPS：%s\n主机：%s\n时间：%s' \
    "$TELEGRAM_VPS_NAME" "$host" "$now"
  curl --disable --silent --show-error --fail --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 8 \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$text" \
    --config - >/dev/null <<EOF
url = "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage"
EOF
}

rotate_telegram_token() {
  local old_chat_id old_vps_name answer
  [ -f "$CONF_DIR/telegram.env" ] || die '未找到现有 Telegram 配置；请先选择“初次部署 / 重新加固 SSH”启用 Telegram 通知。'
  [ -x "$NOTIFIER" ] || die '未找到 Telegram 通知程序；请先选择“初次部署 / 重新加固 SSH”重新写入通知配置。'
  require_root_private_file "$CONF_DIR/telegram.env" 'Telegram 配置'
  # Path is generated and validated by this script.
  # shellcheck disable=SC1091
  source "$CONF_DIR/telegram.env"
  old_chat_id=${TELEGRAM_CHAT_ID:-}
  old_vps_name=${TELEGRAM_VPS_NAME:-$(hostname -f 2>/dev/null || hostname)}
  [ -n "$old_chat_id" ] || die '现有 Telegram 配置缺少 Chat ID；请重新执行初次部署。'

  prompt_block <<'EOF'
注意：Telegram Token 更换步骤如下。
  1. 在 Telegram 搜索 @BotFather，使用 /revoke 使旧 Token 失效并取得新 Token。
  2. 下方粘贴新 Token 后，终端不会显示字符、星号或长度；这是正常的安全保护。
  3. 如果仍使用同一个机器人，Chat ID 通常无需变更。
  4. 此操作只更新 Telegram 配置并发送测试通知；不会修改 SSH、公钥、端口、Fail2ban 或系统软件包。
EOF
  if ! read -rsp "${STYLE_PROMPT}新的 Telegram Bot Token（必填；输入不回显，粘贴后按回车）：${STYLE_RESET}" TELEGRAM_TOKEN; then
    die '未读取到新的 Telegram Bot Token，操作已取消。'
  fi
  printf '\n'
  if ask_yes_no "保留原 Chat ID（$old_chat_id）？" y; then
    TELEGRAM_CHAT_ID=$old_chat_id
  else
    if ! read -r -p "${STYLE_PROMPT}新的 Telegram Chat ID（必填，仅数字）：${STYLE_RESET}" TELEGRAM_CHAT_ID; then
      die '未读取到新的 Telegram Chat ID，操作已取消。'
    fi
  fi
  prompt_default TELEGRAM_VPS_NAME 'Telegram 中显示的 VPS 名称（直接回车保留原名称）' "$old_vps_name"
  validate_telegram_settings

  prompt_block <<EOF
注意：即将更新 Telegram 配置。
  1. Chat ID：$TELEGRAM_CHAT_ID
  2. VPS 名称：$TELEGRAM_VPS_NAME
  3. SSH、公钥、端口、Fail2ban 策略：不修改
EOF
  ask_yes_no '确认更新并发送测试通知？' n || die '已取消，Telegram 配置未修改。'

  if send_telegram_rotation_test; then
    write_telegram_env
    success 'Telegram Token 已更新，测试通知已发送。'
  else
    die '测试通知发送失败，旧 Telegram 配置保持不变。请检查 Token、Chat ID、网络或机器人是否已点击 Start。'
  fi
}

validate_ignore_ip() {
  local entry
  local -a entries

  [ -z "$IGNORE_IP" ] && return 0
  [[ "$IGNORE_IP" != *$'\n'* && "$IGNORE_IP" != *$'\r'* && "$IGNORE_IP" != *[[:space:]]* ]] || \
    die '--ignoreip 只能使用英文逗号分隔的 IP 或 CIDR，不能包含空格或换行。'
  command -v python3 >/dev/null 2>&1 || die '校验 --ignoreip 需要 python3。'

  local IFS=','
  read -r -a entries <<< "$IGNORE_IP"
  [ "${#entries[@]}" -gt 0 ] || die '--ignoreip 不能为空。'
  for entry in "${entries[@]}"; do
    [ -n "$entry" ] || die '--ignoreip 不能包含空项。'
    python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$entry" \
      >/dev/null 2>&1 || die "--ignoreip 包含无效 IP 或 CIDR：$entry"
  done
}

validate_public_key() {
  local key_type bits
  key_type=${PUBLIC_KEY%%[[:space:]]*}

  case "$key_type" in
    ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|\
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa) ;;
    *)
      die 'SSH 公钥必须以受支持的密钥类型开头；推荐使用 ssh-ed25519。不要粘贴 authorized_keys 选项或私钥。'
      ;;
  esac

  printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1 || \
    die '提供的不是有效 SSH 公钥。'
  if [ "$key_type" = ssh-rsa ]; then
    bits=$(printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - | awk 'NR == 1 { print $1 }')
    if ! [[ "$bits" =~ ^[0-9]+$ ]] || [ "$bits" -lt 3072 ]; then
      die 'RSA 公钥至少需要 3072 位；推荐改用 ssh-ed25519。'
    fi
  fi
}

[ "$ROTATE_TELEGRAM" -eq 0 ] || {
  rotate_telegram_token
  exit 0
}

[ -z "$TELEGRAM_TOKEN_FILE" ] || { require_root_private_file "$TELEGRAM_TOKEN_FILE" 'Telegram token'; TELEGRAM_TOKEN=$(head -n 1 "$TELEGRAM_TOKEN_FILE"); }
[ -z "$TELEGRAM_CHAT_ID_FILE" ] || { require_root_private_file "$TELEGRAM_CHAT_ID_FILE" 'Telegram chat id'; TELEGRAM_CHAT_ID=$(head -n 1 "$TELEGRAM_CHAT_ID_FILE"); }
[ -n "$TELEGRAM_TOKEN" ] && [ -z "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
[ -z "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
if [ -n "$TELEGRAM_TOKEN" ]; then
  TELEGRAM_VPS_NAME=${TELEGRAM_VPS_NAME:-$(hostname -f 2>/dev/null || hostname)}
  validate_telegram_settings
fi

if [ -n "$PUBLIC_KEY_FILE" ]; then
  [ -r "$PUBLIC_KEY_FILE" ] || die "无法读取公钥文件：$PUBLIC_KEY_FILE"
  PUBLIC_KEY=$(grep -Em1 '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]' "$PUBLIC_KEY_FILE" || true)
fi
[ -n "$PUBLIC_KEY" ] || die '请粘贴或通过 --public-key-file 提供 .pub 公钥。'
[[ "$PUBLIC_KEY" != *$'\n'* && "$PUBLIC_KEY" != *$'\r'* ]] || die 'SSH 公钥只能是一行；请只粘贴 .pub 文件中的一整行。'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_DIR="$CONF_DIR/backups/$STAMP"
mkdir -p "$BACKUP_DIR"
chmod 700 "$CONF_DIR" "$BACKUP_DIR"
backup_if_exists() {
  if [ -e "$1" ]; then
    cp -a "$1" "$BACKUP_DIR/$2" || die "备份失败：$1"
  fi
}
backup_if_exists "$SSH_DROPIN" ssh-dropin.before
backup_if_exists "$LEGACY_SSH_DROPIN" ssh-dropin-legacy.before
backup_if_exists /etc/pam.d/sshd pam-sshd.before
backup_if_exists /root/.ssh/authorized_keys root-authorized-keys.before
backup_if_exists /root/.ssh/authorized_keys2 root-authorized-keys2.before
backup_if_exists "$F2B_JAIL" fail2ban-jail.before
backup_if_exists "$F2B_ACTION" fail2ban-action.before
backup_if_exists "$F2B_RECIDIVE_JAIL" fail2ban-recidive-jail.before
backup_if_exists "$F2B_LOG_LOCAL" fail2ban-log-local.before
backup_if_exists "$NOTIFIER" telegram-notifier.before
backup_if_exists "$CONF_DIR/telegram.env" telegram-env.before
backup_if_exists "$LEGACY_TELEGRAM_CONTROL" legacy-telegram-control.before
backup_if_exists "$LEGACY_TELEGRAM_CONTROL_SERVICE" legacy-telegram-control-service.before
backup_if_exists "$FIREWALL_CONFIG" firewall-config.before
backup_if_exists "$FIREWALL_TCP_PORTS_FILE" firewall-tcp-ports.before
backup_if_exists "$FIREWALL_UDP_PORTS_FILE" firewall-udp-ports.before
backup_if_exists "$FIREWALL_LOADER" firewall-loader.before
backup_if_exists "$NFTABLES_DROPIN" nftables-dropin.before
systemctl is-active --quiet fail2ban 2>/dev/null && FAIL2BAN_WAS_ACTIVE=1
systemctl is-enabled --quiet fail2ban 2>/dev/null && FAIL2BAN_WAS_ENABLED=1
systemctl is-active --quiet nftables 2>/dev/null && NFTABLES_WAS_ACTIVE=1
systemctl is-enabled --quiet nftables 2>/dev/null && NFTABLES_WAS_ENABLED=1

restore_backup_or_remove() {
  local target=$1 backup_name=$2
  if [ -e "$BACKUP_DIR/$backup_name" ]; then
    rm -f "$target"
    cp -a "$BACKUP_DIR/$backup_name" "$target"
  else
    rm -f "$target"
  fi
}

restore_firewall_state() {
  local target backup_name
  for target in "$FIREWALL_CONFIG" "$FIREWALL_TCP_PORTS_FILE" "$FIREWALL_UDP_PORTS_FILE" "$FIREWALL_LOADER" "$NFTABLES_DROPIN"; do
    case "$target" in
      "$FIREWALL_CONFIG") backup_name=firewall-config.before ;;
      "$FIREWALL_TCP_PORTS_FILE") backup_name=firewall-tcp-ports.before ;;
      "$FIREWALL_UDP_PORTS_FILE") backup_name=firewall-udp-ports.before ;;
      "$FIREWALL_LOADER") backup_name=firewall-loader.before ;;
      "$NFTABLES_DROPIN") backup_name=nftables-dropin.before ;;
    esac
    restore_backup_or_remove "$target" "$backup_name"
  done
  systemctl daemon-reload 2>/dev/null || true
  nft delete table inet "$FIREWALL_TABLE" 2>/dev/null || true
  [ ! -f "$FIREWALL_LOADER" ] || "$FIREWALL_LOADER" 2>/dev/null || true
  if [ "$NFTABLES_WAS_ACTIVE" -eq 0 ]; then
    systemctl stop nftables 2>/dev/null || true
  fi
  if [ "$NFTABLES_WAS_ENABLED" -eq 0 ]; then
    systemctl disable nftables 2>/dev/null || true
  fi
}

restore_ssh_state() {
  printf '%b正在恢复运行前的 SSH 公钥和配置……%b\n' "$STYLE_ERROR" "$STYLE_RESET" >&2
  install -d -o root -g root -m 0700 /root/.ssh
  install -d -m 0755 /etc/ssh/sshd_config.d
  restore_backup_or_remove /root/.ssh/authorized_keys root-authorized-keys.before
  restore_backup_or_remove /root/.ssh/authorized_keys2 root-authorized-keys2.before
  restore_backup_or_remove "$SSH_DROPIN" ssh-dropin.before
  restore_backup_or_remove "$LEGACY_SSH_DROPIN" ssh-dropin-legacy.before
  restore_firewall_state
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || true
  fi
}

restore_fail2ban_state() {
  printf '%b正在恢复运行前的 Fail2ban、PAM 和 Telegram 通知配置……%b\n' "$STYLE_ERROR" "$STYLE_RESET" >&2
  restore_backup_or_remove "$F2B_JAIL" fail2ban-jail.before
  restore_backup_or_remove "$F2B_ACTION" fail2ban-action.before
  restore_backup_or_remove "$F2B_RECIDIVE_JAIL" fail2ban-recidive-jail.before
  restore_backup_or_remove "$F2B_LOG_LOCAL" fail2ban-log-local.before
  restore_backup_or_remove "$NOTIFIER" telegram-notifier.before
  restore_backup_or_remove "$CONF_DIR/telegram.env" telegram-env.before
  restore_backup_or_remove "$LEGACY_TELEGRAM_CONTROL" legacy-telegram-control.before
  restore_backup_or_remove "$LEGACY_TELEGRAM_CONTROL_SERVICE" legacy-telegram-control-service.before
  if [ -e "$BACKUP_DIR/pam-sshd.before" ]; then
    rm -f /etc/pam.d/sshd
    cp -a "$BACKUP_DIR/pam-sshd.before" /etc/pam.d/sshd
  elif [ -e /etc/pam.d/sshd ]; then
    sed -i '/^# vps-security-bootstrap: Telegram SSH login notification$/,+1d' /etc/pam.d/sshd
  fi
  if [ "$FAIL2BAN_WAS_ACTIVE" -eq 1 ]; then
    systemctl restart fail2ban 2>/dev/null || true
  else
    systemctl stop fail2ban 2>/dev/null || true
  fi
  if [ "$FAIL2BAN_WAS_ENABLED" -eq 1 ]; then
    systemctl enable fail2ban 2>/dev/null || true
  else
    systemctl disable fail2ban 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
}

handle_unexpected_error() {
  local status
  status=$1
  trap - ERR
  set +e
  if [ "$FAIL2BAN_MUTATION_ACTIVE" -eq 1 ]; then
    restore_fail2ban_state
  fi
  exit "$status"
}
trap 'handle_unexpected_error $?' ERR

# 清理由旧版本“Telegram 按钮控制”创建的服务；登录异常应按密钥泄露事件处理，
# 不应依赖封禁单个 IP，因此新版本不再提供该控制面。
systemctl disable --now vps-security-telegram-control.service 2>/dev/null || true
rm -f "$LEGACY_TELEGRAM_CONTROL" "$LEGACY_TELEGRAM_CONTROL_SERVICE" \
  /etc/fail2ban/jail.d/manual-telegram-vps-security.local \
  /etc/fail2ban/filter.d/manual-telegram.conf \
  /var/log/vps-security-manual-telegram.log
systemctl daemon-reload

info '安装 Debian 官方软件包（OpenSSH、Fail2ban、nftables、curl）'
export DEBIAN_FRONTEND=noninteractive
if [ -f "$AUTO_UPGRADES_CONF" ]; then
  rm -f "$AUTO_UPGRADES_CONF"
  echo '提示：已移除本工具旧版创建的后台自动更新设置；以后只执行你在向导中明确确认的一次性更新。'
fi
echo '提示：如恰好有其他软件更新正在结束，脚本最多等待 1 分钟；请不要删除任何 lock 文件。'
apt-get -o DPkg::Lock::Timeout=60 update
[ "$SYSTEM_UPGRADE" -eq 0 ] || apt-get -o DPkg::Lock::Timeout=60 upgrade -y
APT_PACKAGES=(openssh-server fail2ban nftables curl iproute2 libpam-modules python3-minimal)
apt-get -o DPkg::Lock::Timeout=60 install -y "${APT_PACKAGES[@]}"
command -v sshd >/dev/null 2>&1 || die '安装 openssh-server 后仍未找到 sshd。'
command -v ssh-keygen >/dev/null 2>&1 || die '安装 OpenSSH 后仍未找到 ssh-keygen。'
command -v ss >/dev/null 2>&1 || die '安装 iproute2 后仍未找到 ss。'
validate_ignore_ip
validate_public_key

CURRENT_SSH_PORT=$(detect_current_ssh_port)
if [ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]; then
  TCP_LISTENER=$(ss -H -ltn "sport = :$SSH_PORT" 2>/dev/null || true)
  UDP_LISTENER=$(ss -H -lun "sport = :$SSH_PORT" 2>/dev/null || true)
  [ -z "$TCP_LISTENER$UDP_LISTENER" ] || \
    die "SSH 端口 $SSH_PORT 已被其他 TCP/UDP 服务监听，请换一个端口。"
fi

info '启用 nftables 默认拒绝入站防火墙（过渡期间同时放行旧/新 SSH 端口）'
if ! configure_nftables_firewall "$CURRENT_SSH_PORT,$SSH_PORT"; then
  die 'nftables 防火墙配置失败；SSH、公钥和 Fail2ban 尚未修改。'
fi

info '覆盖 root 的 SSH 公钥（仅保留本次提供的公钥）'
install -d -o root -g root -m 0700 /root/.ssh
AUTHORIZED_KEYS_TMP=$(mktemp /root/.ssh/authorized_keys.XXXXXX) || die '无法创建 authorized_keys 临时文件。'
if ! printf '%s\n' "$PUBLIC_KEY" > "$AUTHORIZED_KEYS_TMP" ||
  ! chown root:root "$AUTHORIZED_KEYS_TMP" ||
  ! chmod 0600 "$AUTHORIZED_KEYS_TMP"; then
  rm -f "$AUTHORIZED_KEYS_TMP"
  die '准备 authorized_keys 临时文件失败；原公钥未修改。'
fi
if ! mv -f "$AUTHORIZED_KEYS_TMP" /root/.ssh/authorized_keys ||
  ! rm -f /root/.ssh/authorized_keys2; then
  rm -f "$AUTHORIZED_KEYS_TMP"
  restore_ssh_state
  die '安装 root SSH 公钥失败；已恢复运行前状态。'
fi

info '写入 SSH 加固配置（只管理自己的 drop-in 文件）'
install -d -m 0755 /etc/ssh/sshd_config.d
# 旧版本使用 99- 前缀。OpenSSH 对大多数单值配置采用首次读取的值，
# 因此先移除本工具旧文件，再以 00- 前缀写入当前策略。
rm -f "$LEGACY_SSH_DROPIN"
SSH_DROPIN_TMP=$(mktemp /etc/ssh/sshd_config.d/00-vps-security-bootstrap.conf.XXXXXX) || {
  restore_ssh_state
  die '无法创建 SSH 配置临时文件。'
}
if ! cat > "$SSH_DROPIN_TMP" <<EOF
# Managed by $APP.
Port $SSH_PORT
PermitRootLogin prohibit-password
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
AuthorizedKeysFile .ssh/authorized_keys
AuthorizedKeysCommand none
TrustedUserCAKeys none
StrictModes yes
HostbasedAuthentication no
IgnoreRhosts yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes

DisableForwarding yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no

MaxAuthTries 3
MaxSessions 5
LoginGraceTime 20
MaxStartups 10:30:60
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
UseDNS no
LogLevel VERBOSE
EOF
then
  rm -f "$SSH_DROPIN_TMP"
  restore_ssh_state
  die '写入 SSH 配置临时文件失败；已恢复运行前状态。'
fi
if ! chmod 0644 "$SSH_DROPIN_TMP" || ! mv -f "$SSH_DROPIN_TMP" "$SSH_DROPIN"; then
  rm -f "$SSH_DROPIN_TMP"
  restore_ssh_state
  die '安装 SSH 配置失败；已恢复运行前状态。'
fi

info '校验 SSH 配置及最终生效策略'
sshd_effective() {
  sshd -T | awk -v key="$1" '$1 == key { $1=""; sub(/^ /, ""); print }'
}
assert_sshd_single_value() {
  local key=$1 expected=$2 actual count
  actual=$(sshd_effective "$key")
  count=$(printf '%s\n' "$actual" | sed '/^$/d' | wc -l)
  if [ "$count" -eq 1 ] && [ "$actual" = "$expected" ]; then
    return 0
  fi
  printf 'SSH 最终配置 %s 应为 %q，实际为 %q。\n' \
    "$key" "$expected" "${actual:-<未设置>}" >&2
  return 1
}

validate_sshd_policy() {
  sshd -t &&
    assert_sshd_single_value port "$SSH_PORT" &&
    assert_sshd_single_value permitrootlogin without-password &&
    assert_sshd_single_value allowusers root &&
    assert_sshd_single_value pubkeyauthentication yes &&
    assert_sshd_single_value authenticationmethods publickey &&
    assert_sshd_single_value authorizedkeysfile .ssh/authorized_keys &&
    assert_sshd_single_value authorizedkeyscommand none &&
    assert_sshd_single_value trustedusercakeys none &&
    assert_sshd_single_value strictmodes yes &&
    assert_sshd_single_value hostbasedauthentication no &&
    assert_sshd_single_value ignorerhosts yes &&
    assert_sshd_single_value passwordauthentication no &&
    assert_sshd_single_value kbdinteractiveauthentication no &&
    assert_sshd_single_value disableforwarding yes &&
    assert_sshd_single_value allowtcpforwarding no &&
    assert_sshd_single_value allowagentforwarding no &&
    assert_sshd_single_value x11forwarding no &&
    assert_sshd_single_value permittunnel no
}

if ! validate_sshd_policy; then
  restore_ssh_state
  die 'SSH 配置校验失败；已恢复运行前的 SSH 公钥和配置，未应用新策略。'
fi

info '应用 SSH 配置'
if ! systemctl reload ssh; then
  restore_ssh_state
  die 'SSH 服务重载失败；已恢复运行前的 SSH 公钥和配置。'
fi

info '收敛 nftables 防火墙为仅放行新 SSH 端口和已配置的额外端口'
if ! configure_nftables_firewall "$SSH_PORT"; then
  restore_ssh_state
  die 'nftables 防火墙收敛失败；已恢复运行前的 SSH 公钥和配置。请保持当前会话并检查防火墙状态。'
fi

info '写入 Fail2ban 配置（systemd journal + nftables）'
FAIL2BAN_MUTATION_ACTIVE=1
if [ -n "$TELEGRAM_TOKEN" ]; then
  write_telegram_env
  cat > "$NOTIFIER" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
ENV_FILE=/etc/vps-security/telegram.env
[ -r "$ENV_FILE" ] || exit 0
# 该文件由本脚本以 root:root 0600 原子写入。
# shellcheck disable=SC1090
source "$ENV_FILE"
html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
root_ssh_sources_html() {
  local source found=0
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    printf '• <code>%s</code>\n' "$(html_escape "$source")"
    found=1
  done < <(
    {
      who | awk '$1 == "root" && $NF ~ /^\([^()]+\)$/ { value=$NF; gsub(/[()]/, "", value); print value }'
      [ -n "${PAM_RHOST:-}" ] && printf '%s\n' "$PAM_RHOST"
    } | awk 'NF && !seen[$0]++'
  )
  [ "$found" -eq 1 ] || printf '• 未检测到 root SSH 会话\n'
}
format_duration() {
  local seconds=$1
  case "$seconds" in
    -1|0|'') printf '永久' ;;
    *[!0-9]*) printf '%s' "$seconds" ;;
    *)
      if [ "$seconds" -ge 86400 ] && [ $((seconds % 86400)) -eq 0 ]; then printf '%s 天' $((seconds / 86400))
      elif [ "$seconds" -ge 3600 ] && [ $((seconds % 3600)) -eq 0 ]; then printf '%s 小时' $((seconds / 3600))
      elif [ "$seconds" -ge 60 ] && [ $((seconds % 60)) -eq 0 ]; then printf '%s 分钟' $((seconds / 60))
      else printf '%s 秒' "$seconds"; fi
      ;;
  esac
}
send() {
  local text=$1
  local -a args=(--data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$text" --data-urlencode 'parse_mode=HTML' --data-urlencode 'disable_web_page_preview=true')
  curl --disable --silent --show-error --fail --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 8 "${args[@]}" \
    --config - >/dev/null <<CURL_CONFIG_EOF || true
url = "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage"
CURL_CONFIG_EOF
}
event=$1
host=$(hostname -f 2>/dev/null || hostname)
now=$(date -u -d '+8 hours' '+%Y-%m-%d %H:%M:%S 北京时间 (UTC+8)')
name=$(html_escape "$TELEGRAM_VPS_NAME")
host=$(html_escape "$host")
case "$event" in
  login)
    [ "$PAM_SERVICE" = sshd ] && [ "$PAM_TYPE" = open_session ] || exit 0
    ip=${PAM_RHOST:-unknown}
    root_ssh_sources=$(root_ssh_sources_html)
    send "<b>✅ SSH 公钥登录成功</b>
<b>📌 $name</b>
━━━━━━━━━━━━
🖥 主机：<code>$host</code>
👤 用户：<code>$(html_escape "$PAM_USER")</code>
🌐 来源 IP：<code>$(html_escape "$ip")</code>
🔐 当前 root SSH 会话 IP：
$root_ssh_sources
🕒 时间：<code>$now</code>"
    ;;
  ban)
    ip=$2 jail=$3 duration=${4:-} count=${5:-}
    send "<b>🚨 Fail2ban 已自动封禁</b>
<b>📌 $name</b>
━━━━━━━━━━━━
🖥 主机：<code>$host</code>
🛡 Jail：<code>$(html_escape "$jail")</code>
🌐 IP：<code>$(html_escape "$ip")</code>
⏳ 本次封禁：<b>$(format_duration "$duration")</b>
🔁 历史封禁次数：<b>${count:-未知}</b>
🕒 时间：<code>$now</code>"
    ;;
esac
EOF
  chmod 0700 "$NOTIFIER"
  cat > "$F2B_ACTION" <<'EOF'
[Definition]
actionban = /usr/local/sbin/vps-security-notify ban '<ip>' '<name>' '<bantime>' '<bancount>'
EOF
  sed -i '/^# vps-security-bootstrap: Telegram SSH login notification$/,+1d' /etc/pam.d/sshd
  cat >> /etc/pam.d/sshd <<'EOF'
# vps-security-bootstrap: Telegram SSH login notification
session optional pam_exec.so quiet type=open_session /usr/local/sbin/vps-security-notify login
EOF
else
  rm -f "$F2B_ACTION" "$NOTIFIER" "$CONF_DIR/telegram.env"
  sed -i '/^# vps-security-bootstrap: Telegram SSH login notification$/,+1d' /etc/pam.d/sshd
fi

IGNORE_LINE='127.0.0.1/8 ::1'
[ -z "$IGNORE_IP" ] || IGNORE_IP=$(printf '%s' "$IGNORE_IP" | tr ',' ' ')
[ -z "$IGNORE_IP" ] || IGNORE_LINE="$IGNORE_LINE $IGNORE_IP"
cat > "$F2B_JAIL" <<EOF
[DEFAULT]
ignoreip = $IGNORE_LINE

[sshd]
enabled = true
backend = systemd
usedns = no
port = $SSH_PORT
banaction = nftables-multiport
bantime = $BANTIME
findtime = 3m
maxretry = 3
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 4w
EOF
if [ -n "$TELEGRAM_TOKEN" ]; then
  cat >> "$F2B_JAIL" <<'EOF'
action = %(action_)s
         vps-security-telegram
EOF
fi

# 对持续多次触发封禁的来源单独处理。普通 sshd jail 仍保留可恢复的递增封禁；
# recidive 只有在 30 天内累计 5 次完整封禁后才永久封禁，避免一次误判长期影响动态 IP。
install -d -m 0755 /etc/fail2ban/fail2ban.d
touch /var/log/fail2ban.log
chmod 0640 /var/log/fail2ban.log
cat > "$F2B_LOG_LOCAL" <<'EOF'
[Definition]
logtarget = /var/log/fail2ban.log
dbpurgeage = 60d
EOF
cat > "$F2B_RECIDIVE_JAIL" <<'EOF'
[recidive]
enabled = true
backend = polling
logpath = /var/log/fail2ban.log*
banaction = nftables-allports
bantime = -1
findtime = 30d
maxretry = 5
EOF
if [ -n "$TELEGRAM_TOKEN" ]; then
  cat >> "$F2B_RECIDIVE_JAIL" <<'EOF'
action = %(action_)s
         vps-security-telegram
EOF
fi

info '校验并启动 Fail2ban'
if ! fail2ban-client -d >/dev/null; then
  restore_fail2ban_state
  die 'Fail2ban 配置校验失败；已恢复运行前的 Fail2ban、PAM 和 Telegram 通知配置。'
fi
if ! systemctl enable fail2ban; then
  restore_fail2ban_state
  die 'Fail2ban 开机启动配置失败；已恢复运行前的 Fail2ban、PAM 和 Telegram 通知配置。'
fi
if ! systemctl restart fail2ban; then
  restore_fail2ban_state
  die 'Fail2ban 启动失败；已恢复运行前的 Fail2ban、PAM 和 Telegram 通知配置。'
fi
for ((attempt = 1; attempt <= 20; attempt++)); do
  fail2ban-client ping >/dev/null 2>&1 && break
  sleep 0.5
done
fail2ban-client ping >/dev/null 2>&1 || {
  systemctl status fail2ban --no-pager -l >&2 || true
  restore_fail2ban_state
  die 'Fail2ban 在 10 秒内未就绪；已恢复运行前配置，请查看上方服务状态。'
}
fail2ban-client status sshd
FAIL2BAN_MUTATION_ACTIVE=0

cat <<EOF

完成。请另开一个终端验证：
  ssh -p $SSH_PORT root@<你的服务器IP>
EOF
echo '本工具不创建 SSH 自动回滚；新连接验证成功前，请保持当前 SSH 窗口打开。'
[ -n "$TELEGRAM_TOKEN" ] && printf 'Telegram 已启用：通知将以“%s”显示，请确保该聊天仅对可信成员开放。\n' "$TELEGRAM_VPS_NAME"
echo '注意：请在云厂商安全组/防火墙中先放行新的 SSH 端口。'
