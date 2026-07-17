#!/usr/bin/env bash
# Debian 12/13 SSH hardening + Fail2ban + optional Telegram notifications.
set -Eeuo pipefail
IFS=$'\n\t'

readonly APP='vps-security-bootstrap'
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
readonly CONFIRM='/usr/local/sbin/vps-security-confirm'
readonly AUTO_UPGRADES_CONF='/etc/apt/apt.conf.d/52-vps-security-bootstrap-auto-upgrades'
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
ROLLBACK_SECONDS=600
SCHEDULE_ROLLBACK=1
SYSTEM_UPGRADE=1
INTERACTIVE=0
INTERACTIVE_FLAG=0
ORIGINAL_ARGC=$#

usage() {
  cat <<'EOF'

普通用法（推荐，逐项填写）：
  sudo bash bootstrap.sh

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
  --permanent-bans             永久封禁（不推荐，默认逐级延长至 4 周）
  --skip-system-upgrade        跳过本次 apt upgrade（不推荐；仍安装所需软件包）
  --no-rollback                不创建 10 分钟自动回滚保护（不推荐）
  -h, --help                   显示本帮助
EOF
}
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 需要一个值"; }

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
    --skip-system-upgrade) SYSTEM_UPGRADE=0; shift ;;
    --no-rollback) SCHEDULE_ROLLBACK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done

[ "$ORIGINAL_ARGC" -eq 0 ] && INTERACTIVE=1
[ "$INTERACTIVE_FLAG" -eq 0 ] || [ "$ORIGINAL_ARGC" -eq 1 ] || die '--interactive 不能与其他参数同时使用。'

prompt_default() {
  local variable=$1 prompt=$2 default=$3 value
  read -r -p "$prompt [$default]: " value
  printf -v "$variable" '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt=$1 default=${2:-y} answer
  while true; do
    if [ "$default" = y ]; then
      read -r -p "$prompt [Y/n]: " answer
      answer=${answer:-y}
    else
      read -r -p "$prompt [y/N]: " answer
      answer=${answer:-n}
    fi
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo '请输入 y 或 n。' ;;
    esac
  done
}

detect_current_ssh_port() {
  if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    sshd -T | awk '$1 == "port" { print $2; exit }'
  else
    printf '22'
  fi
}

prompt_for_public_key() {
  echo
  echo '请从你的电脑复制 .pub 文件的完整一行内容，然后粘贴到下方并按回车。'
  echo '示例：ssh-ed25519 AAAA... your-computer'
  read -r -p 'root SSH 公钥：' PUBLIC_KEY
}

interactive_wizard() {
  local current_port answer
  [ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh'
  [ -t 0 ] || die '交互式向导需要终端；自动化运行请传入 --public-key-file 等参数。'
  clear 2>/dev/null || true
  cat <<'EOF'
========================================
 Debian VPS 安全初始化向导（Debian 12 / 13）
========================================
将保留 root 作为唯一 SSH 用户，只允许你提供的 SSH 公钥登录，
关闭 SSH 密码登录，
启用 Fail2ban 和自动安全更新。当前 SSH 连接请保持打开，直到最后验证成功。
EOF
  prompt_for_public_key
  current_port=$(detect_current_ssh_port)
  prompt_default SSH_PORT '新的 SSH 端口（默认保持当前端口，避免云防火墙拦截）' "$current_port"
  if [ "$SSH_PORT" != "$current_port" ]; then
    echo "注意：你选择将 SSH 端口从 $current_port 改为 $SSH_PORT。"
    echo '请先在云厂商安全组/防火墙中放行新端口，否则新连接会失败。'
    ask_yes_no '已确认新端口已放行吗？' n || die '已取消；请先放行新端口后再运行。'
  fi
  prompt_default IGNORE_IP 'Fail2ban 永不封禁的固定管理 IP/CIDR（没有就直接回车）' ''
  if ask_yes_no '现在执行系统软件升级？' y; then SYSTEM_UPGRADE=1; else SYSTEM_UPGRADE=0; fi
  if ask_yes_no '启用 Telegram 登录/封禁通知？' n; then
    read -rsp 'Telegram Bot Token（输入不回显）：' TELEGRAM_TOKEN
    printf '\n'
    read -r -p 'Telegram Chat ID：' TELEGRAM_CHAT_ID
    [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || die 'Telegram Token 和 Chat ID 都不能为空。'
    prompt_default TELEGRAM_VPS_NAME 'Telegram 中显示的 VPS 名称' "$(hostname -f 2>/dev/null || hostname)"
  fi
  echo
  echo '即将应用以下设置：'
  echo '  SSH 用户：root（仅 SSH 公钥登录）'
  echo "  SSH 端口：$SSH_PORT"
  echo "  系统立即升级：$([ "$SYSTEM_UPGRADE" -eq 1 ] && echo 是 || echo 否)"
  echo "  Telegram 通知：$([ -n "$TELEGRAM_TOKEN" ] && echo 是 || echo 否)"
  [ -z "$TELEGRAM_TOKEN" ] || echo "  Telegram 名称：${TELEGRAM_VPS_NAME:-$(hostname)}"
  echo '  SSH 回滚保护：10 分钟内未确认将自动还原本脚本写入的 SSH 配置'
  read -r -p '确认开始请输入 YES：' answer
  [ "$answer" = YES ] || die '已取消，未修改系统。'
}

[ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh …'
[ -r /etc/debian_version ] || die '此脚本仅面向 Debian 12 或 13。'
. /etc/os-release
[ "$ID" = debian ] || die '此脚本仅支持 Debian。'
case "${VERSION_ID%%.*}" in
  12|13) ;;
  *) die '此脚本仅支持 Debian 12 或 13。' ;;
esac
[ -d /run/systemd/system ] || die '此脚本需要 systemd。'
[ "$INTERACTIVE" -eq 0 ] || interactive_wizard
[[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$SSH_PORT" -le 65535 ] || die '--ssh-port 必须是 1–65535。'
[ -z "$PUBLIC_KEY" ] || [ -z "$PUBLIC_KEY_FILE" ] || die '只能使用一种公钥传入方式。'
require_root_private_file() {
  local path=$1 label=$2 owner mode
  [ -f "$path" ] && [ -r "$path" ] || die "无法读取 $label 文件：$path"
  owner=$(stat -c '%u' "$path")
  mode=$(stat -c '%a' "$path")
  [ "$owner" -eq 0 ] || die "$label 文件必须由 root 所有：$path"
  (( (8#$mode & 077) == 0 )) || die "$label 文件权限必须是 0600 或更严格：$path"
}
[ -z "$TELEGRAM_TOKEN_FILE" ] || { require_root_private_file "$TELEGRAM_TOKEN_FILE" 'Telegram token'; TELEGRAM_TOKEN=$(head -n 1 "$TELEGRAM_TOKEN_FILE"); }
[ -z "$TELEGRAM_CHAT_ID_FILE" ] || { require_root_private_file "$TELEGRAM_CHAT_ID_FILE" 'Telegram chat id'; TELEGRAM_CHAT_ID=$(head -n 1 "$TELEGRAM_CHAT_ID_FILE"); }
[ -n "$TELEGRAM_TOKEN" ] && [ -z "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
[ -z "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
[ -z "$TELEGRAM_TOKEN" ] || TELEGRAM_VPS_NAME=${TELEGRAM_VPS_NAME:-$(hostname -f 2>/dev/null || hostname)}
[ -z "$TELEGRAM_VPS_NAME" ] || [[ "$TELEGRAM_VPS_NAME" != *$'\n'* && "$TELEGRAM_VPS_NAME" != *$'\r'* && ${#TELEGRAM_VPS_NAME} -le 80 ]] || die 'Telegram VPS 名称不能包含换行，且最多 80 个字符。'

if [ -n "$PUBLIC_KEY_FILE" ]; then
  [ -r "$PUBLIC_KEY_FILE" ] || die "无法读取公钥文件：$PUBLIC_KEY_FILE"
  PUBLIC_KEY=$(grep -E '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-ed25519)' "$PUBLIC_KEY_FILE" | head -n 1 || true)
fi
[ -n "$PUBLIC_KEY" ] || die '请粘贴或通过 --public-key-file 提供 .pub 公钥。'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$CONF_DIR/backups/$STAMP"
ROLLBACK_SCRIPT="$CONF_DIR/rollback-ssh-$STAMP.sh"
mkdir -p "$BACKUP_DIR"
chmod 700 "$CONF_DIR" "$BACKUP_DIR"
backup_if_exists() { [ -e "$1" ] && cp -a "$1" "$BACKUP_DIR/$2" || true; }
backup_if_exists "$SSH_DROPIN" ssh-dropin.before
backup_if_exists "$LEGACY_SSH_DROPIN" ssh-dropin-legacy.before
backup_if_exists /etc/pam.d/sshd pam-sshd.before
backup_if_exists /root/.ssh/authorized_keys root-authorized-keys.before
backup_if_exists "$F2B_JAIL" fail2ban-jail.before
backup_if_exists "$F2B_ACTION" fail2ban-action.before
backup_if_exists "$F2B_RECIDIVE_JAIL" fail2ban-recidive-jail.before
backup_if_exists "$F2B_LOG_LOCAL" fail2ban-log-local.before
backup_if_exists "$NOTIFIER" telegram-notifier.before
backup_if_exists "$CONF_DIR/telegram.env" telegram-env.before
backup_if_exists "$LEGACY_TELEGRAM_CONTROL" legacy-telegram-control.before
backup_if_exists "$LEGACY_TELEGRAM_CONTROL_SERVICE" legacy-telegram-control-service.before

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
apt-get update
[ "$SYSTEM_UPGRADE" -eq 0 ] || apt-get upgrade -y
apt-get install -y openssh-server fail2ban nftables curl libpam-modules unattended-upgrades
command -v sshd >/dev/null 2>&1 || die '安装 openssh-server 后仍未找到 sshd。'
command -v ssh-keygen >/dev/null 2>&1 || die '安装 OpenSSH 后仍未找到 ssh-keygen。'
printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1 || die '提供的不是有效 SSH 公钥。'
cat > "$AUTO_UPGRADES_CONF" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

info '写入 root 的 SSH 公钥'
install -d -o root -g root -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -Fqx "$PUBLIC_KEY" /root/.ssh/authorized_keys || printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys

info '写入 SSH 加固配置（只管理自己的 drop-in 文件）'
install -d -m 0755 /etc/ssh/sshd_config.d
# 旧版本使用 99- 前缀。OpenSSH 对大多数单值配置采用首次读取的值，
# 因此先移除本工具旧文件，再以 00- 前缀写入当前策略。
rm -f "$LEGACY_SSH_DROPIN"
cat > "$SSH_DROPIN" <<EOF
# Managed by $APP.
Port $SSH_PORT
PermitRootLogin yes
AllowUsers root
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
UsePAM yes

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
chmod 0644 "$SSH_DROPIN"

info '校验 SSH 配置及最终生效策略'
sshd -t
sshd_effective() {
  sshd -T | awk -v key="$1" '$1 == key { $1=""; sub(/^ /, ""); print }'
}
assert_sshd_single_value() {
  local key=$1 expected=$2 actual count
  actual=$(sshd_effective "$key")
  count=$(printf '%s\n' "$actual" | sed '/^$/d' | wc -l)
  [ "$count" -eq 1 ] && [ "$actual" = "$expected" ] || \
    die "SSH 最终配置 $key 应为 '$expected'，实际为 '${actual:-<未设置>}'；脚本没有重载 SSH。"
}
assert_sshd_single_value port "$SSH_PORT"
assert_sshd_single_value permitrootlogin yes
assert_sshd_single_value allowusers root
assert_sshd_single_value pubkeyauthentication yes
assert_sshd_single_value authenticationmethods publickey
assert_sshd_single_value passwordauthentication no
assert_sshd_single_value kbdinteractiveauthentication no
assert_sshd_single_value allowtcpforwarding no
assert_sshd_single_value allowagentforwarding no
assert_sshd_single_value x11forwarding no
assert_sshd_single_value permittunnel no

if [ "$SCHEDULE_ROLLBACK" -eq 1 ]; then
  info "创建 $ROLLBACK_SECONDS 秒自动回滚保护"
  cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -e '$BACKUP_DIR/ssh-dropin.before' ]; then
  cp -a '$BACKUP_DIR/ssh-dropin.before' '$SSH_DROPIN'
else
  rm -f '$SSH_DROPIN'
fi
if [ -e '$BACKUP_DIR/ssh-dropin-legacy.before' ]; then
  cp -a '$BACKUP_DIR/ssh-dropin-legacy.before' '$LEGACY_SSH_DROPIN'
else
  rm -f '$LEGACY_SSH_DROPIN'
fi
sshd -t && systemctl reload ssh
EOF
  chmod 0700 "$ROLLBACK_SCRIPT"
  ROLLBACK_UNIT="vps-security-ssh-rollback-$STAMP"
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="$ROLLBACK_SECONDS"s "$ROLLBACK_SCRIPT"
  cat > "$CONFIRM" <<EOF
#!/usr/bin/env bash
set -euo pipefail
systemctl stop '$ROLLBACK_UNIT.timer' '$ROLLBACK_UNIT.service' 2>/dev/null || true
systemctl reset-failed '$ROLLBACK_UNIT.timer' '$ROLLBACK_UNIT.service' 2>/dev/null || true
rm -f '$ROLLBACK_SCRIPT' "\$0"
echo 'SSH 配置已确认，自动回滚已取消。'
EOF
  chmod 0700 "$CONFIRM"
fi

info '应用 SSH 配置'
systemctl reload ssh

info '写入 Fail2ban 配置（systemd journal + nftables）'
if [ -n "$TELEGRAM_TOKEN" ]; then
  printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\nTELEGRAM_VPS_NAME=%q\n' \
    "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT_ID" "$TELEGRAM_VPS_NAME" > "$CONF_DIR/telegram.env"
  chmod 0600 "$CONF_DIR/telegram.env"
  cat > "$NOTIFIER" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
ENV_FILE=/etc/vps-security/telegram.env
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"
html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
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
  curl --silent --show-error --fail --connect-timeout 3 --max-time 8 "${args[@]}" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null || true
}
event=$1
host=$(hostname -f 2>/dev/null || hostname)
now=$(date -u '+%Y-%m-%d %H:%M:%SZ')
name=$(html_escape "$TELEGRAM_VPS_NAME")
host=$(html_escape "$host")
case "$event" in
  login)
    [ "$PAM_SERVICE" = sshd ] && [ "$PAM_TYPE" = open_session ] || exit 0
    ip=${PAM_RHOST:-unknown}
    send "<b>✅ SSH 公钥登录成功</b>
<b>📌 $name</b>
━━━━━━━━━━━━
🖥 主机：<code>$host</code>
👤 用户：<code>$(html_escape "$PAM_USER")</code>
🌐 来源 IP：<code>$(html_escape "$ip")</code>
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
backend = systemd
usedns = no
bantime = $BANTIME
findtime = 10m
maxretry = 3
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 4w
ignoreip = $IGNORE_LINE

[sshd]
enabled = true
port = $SSH_PORT
banaction = nftables-multiport
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
fail2ban-client -d >/dev/null
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client ping >/dev/null
fail2ban-client status sshd

cat <<EOF

完成。请另开一个终端验证：
  ssh -p $SSH_PORT root@<你的服务器IP>
EOF
if [ "$SCHEDULE_ROLLBACK" -eq 1 ]; then
  echo "确认新登录成功后，立刻执行：$CONFIRM"
  echo "若 $ROLLBACK_SECONDS 秒内没有确认，SSH drop-in 会自动回滚。"
fi
[ -n "$TELEGRAM_TOKEN" ] && echo "Telegram 已启用：通知将以“$TELEGRAM_VPS_NAME”显示，请确保该聊天仅对可信成员开放。"
echo '注意：请在云厂商安全组/防火墙中先放行新的 SSH 端口。'
