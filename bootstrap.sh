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
readonly NOTIFIER='/usr/local/sbin/vps-security-notify'
readonly CONFIRM='/usr/local/sbin/vps-security-confirm'
readonly AUTO_UPGRADES_CONF='/etc/apt/apt.conf.d/52-vps-security-bootstrap-auto-upgrades'
SSH_PORT=52022
ADMIN_USER=admin
PUBLIC_KEY=''
PUBLIC_KEY_FILE=''
ADMIN_PASSWORD_FILE=''
ALLOW_NOPASSWD_SUDO=0
IGNORE_IP=''
TELEGRAM_TOKEN=''
TELEGRAM_CHAT_ID=''
TELEGRAM_TOKEN_FILE=''
TELEGRAM_CHAT_ID_FILE=''
BANTIME=1d
ROLLBACK_SECONDS=600
SCHEDULE_ROLLBACK=1
SYSTEM_UPGRADE=1

usage() {
  cat <<'EOF'
用法：
  sudo bash bootstrap.sh --public-key-file /path/to/id_ed25519.pub [选项]

必填（二选一）：
  --public-key-file PATH       管理员 SSH 公钥文件（推荐）
  --public-key 'ssh-ed25519 …' 管理员 SSH 公钥文本

选项：
  --admin-user NAME            新建的唯一 SSH 管理用户，默认：admin
  --ssh-port PORT              SSH 端口，默认：52022
  --ignoreip CIDR[,CIDR...]    Fail2ban 永不封禁的可信 IP/CIDR（可选）
  --telegram-token-file PATH   从 root 可读文件读取 token（推荐，避免出现在历史记录）
  --telegram-chat-id-file PATH 从 root 可读文件读取 chat id（推荐）
  --admin-password-file PATH   自动化运行时从单行文件读取管理员 sudo 密码
  --allow-nopasswd-sudo         允许管理员免密 sudo（不推荐；私钥失窃即获得 root）
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
    --public-key-file) need_value "$@"; PUBLIC_KEY_FILE=$2; shift 2 ;;
    --public-key) need_value "$@"; PUBLIC_KEY=$2; shift 2 ;;
    --admin-password-file) need_value "$@"; ADMIN_PASSWORD_FILE=$2; shift 2 ;;
    --allow-nopasswd-sudo) ALLOW_NOPASSWD_SUDO=1; shift ;;
    --admin-user) need_value "$@"; ADMIN_USER=$2; shift 2 ;;
    --ssh-port) need_value "$@"; SSH_PORT=$2; shift 2 ;;
    --ignoreip) need_value "$@"; IGNORE_IP=$2; shift 2 ;;
    --telegram-token|--telegram-chat-id)
      die '为避免 token 泄露到 shell 历史或进程参数，请使用 --telegram-token-file 和 --telegram-chat-id-file。'
      ;;
    --telegram-token-file) need_value "$@"; TELEGRAM_TOKEN_FILE=$2; shift 2 ;;
    --telegram-chat-id-file) need_value "$@"; TELEGRAM_CHAT_ID_FILE=$2; shift 2 ;;
    --permanent-bans) BANTIME=-1; shift ;;
    --skip-system-upgrade) SYSTEM_UPGRADE=0; shift ;;
    --no-rollback) SCHEDULE_ROLLBACK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done

[ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh …'
[ -r /etc/debian_version ] || die '此脚本仅面向 Debian 12 或 13。'
. /etc/os-release
[ "$ID" = debian ] || die '此脚本仅支持 Debian。'
case "${VERSION_ID%%.*}" in
  12|13) ;;
  *) die '此脚本仅支持 Debian 12 或 13。' ;;
esac
[ -d /run/systemd/system ] || die '此脚本需要 systemd。'
[[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$SSH_PORT" -le 65535 ] || die '--ssh-port 必须是 1–65535。'
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die '--admin-user 格式不正确。'
[ -z "$PUBLIC_KEY" ] || [ -z "$PUBLIC_KEY_FILE" ] || die '只能使用一种公钥传入方式。'
require_root_private_file() {
  local path=$1 label=$2 owner mode
  [ -f "$path" ] && [ -r "$path" ] || die "无法读取 $label 文件：$path"
  owner=$(stat -c '%u' "$path")
  mode=$(stat -c '%a' "$path")
  [ "$owner" -eq 0 ] || die "$label 文件必须由 root 所有：$path"
  (( (8#$mode & 077) == 0 )) || die "$label 文件权限必须是 0600 或更严格：$path"
}
[ -z "$ADMIN_PASSWORD_FILE" ] || require_root_private_file "$ADMIN_PASSWORD_FILE" '管理员密码'
[ -z "$TELEGRAM_TOKEN_FILE" ] || { require_root_private_file "$TELEGRAM_TOKEN_FILE" 'Telegram token'; TELEGRAM_TOKEN=$(head -n 1 "$TELEGRAM_TOKEN_FILE"); }
[ -z "$TELEGRAM_CHAT_ID_FILE" ] || { require_root_private_file "$TELEGRAM_CHAT_ID_FILE" 'Telegram chat id'; TELEGRAM_CHAT_ID=$(head -n 1 "$TELEGRAM_CHAT_ID_FILE"); }
[ -n "$TELEGRAM_TOKEN" ] && [ -z "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
[ -z "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'

if [ -n "$ADMIN_PASSWORD_FILE" ]; then
  ADMIN_PASSWORD=$(head -n 1 "$ADMIN_PASSWORD_FILE")
  [ -n "$ADMIN_PASSWORD" ] || die '管理员密码文件的第一行不能为空。'
elif [ "$ALLOW_NOPASSWD_SUDO" -eq 0 ]; then
  [ -t 0 ] || die '非交互运行时请使用 --admin-password-file，或明确传入 --allow-nopasswd-sudo。'
  read -rsp "为 $ADMIN_USER 设置 sudo 密码（不会用于 SSH 登录）：" ADMIN_PASSWORD
  printf '\n'
  read -rsp '再次输入 sudo 密码：' ADMIN_PASSWORD_CONFIRM
  printf '\n'
  [ -n "$ADMIN_PASSWORD" ] || die 'sudo 密码不能为空。'
  [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ] || die '两次输入的 sudo 密码不一致。'
  unset ADMIN_PASSWORD_CONFIRM
fi
[ "$ALLOW_NOPASSWD_SUDO" -eq 1 ] || [[ "$ADMIN_PASSWORD" != *:* ]] || die 'sudo 密码不能包含冒号。'

if [ -n "$PUBLIC_KEY_FILE" ]; then
  [ -r "$PUBLIC_KEY_FILE" ] || die "无法读取公钥文件：$PUBLIC_KEY_FILE"
  PUBLIC_KEY=$(grep -E '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-ed25519)' "$PUBLIC_KEY_FILE" | head -n 1 || true)
fi
[ -n "$PUBLIC_KEY" ] || die '请用 --public-key-file 提供 .pub 公钥。'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$CONF_DIR/backups/$STAMP"
ROLLBACK_SCRIPT="$CONF_DIR/rollback-ssh-$STAMP.sh"
mkdir -p "$BACKUP_DIR"
chmod 700 "$CONF_DIR" "$BACKUP_DIR"
backup_if_exists() { [ -e "$1" ] && cp -a "$1" "$BACKUP_DIR/$2" || true; }
backup_if_exists "$SSH_DROPIN" ssh-dropin.before
backup_if_exists "$LEGACY_SSH_DROPIN" ssh-dropin-legacy.before
backup_if_exists /etc/pam.d/sshd pam-sshd.before
backup_if_exists "$F2B_JAIL" fail2ban-jail.before
backup_if_exists "$F2B_ACTION" fail2ban-action.before

info '安装 Debian 官方软件包（OpenSSH、Fail2ban、nftables、curl）'
export DEBIAN_FRONTEND=noninteractive
apt-get update
[ "$SYSTEM_UPGRADE" -eq 0 ] || apt-get upgrade -y
apt-get install -y openssh-server fail2ban nftables curl sudo libpam-modules unattended-upgrades
command -v sshd >/dev/null 2>&1 || die '安装 openssh-server 后仍未找到 sshd。'
command -v ssh-keygen >/dev/null 2>&1 || die '安装 OpenSSH 后仍未找到 ssh-keygen。'
printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1 || die '提供的不是有效 SSH 公钥。'
cat > "$AUTO_UPGRADES_CONF" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

info "创建/更新管理员用户：$ADMIN_USER"
id "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos '' "$ADMIN_USER"
USER_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || die "无法确定 $ADMIN_USER 的家目录。"
usermod -aG sudo "$ADMIN_USER"
passwd -l "$ADMIN_USER" >/dev/null 2>&1 || true
install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0700 "$USER_HOME/.ssh"
touch "$USER_HOME/.ssh/authorized_keys"
grep -Fqx "$PUBLIC_KEY" "$USER_HOME/.ssh/authorized_keys" || printf '%s\n' "$PUBLIC_KEY" >> "$USER_HOME/.ssh/authorized_keys"
chown "$ADMIN_USER:$ADMIN_USER" "$USER_HOME/.ssh/authorized_keys"
chmod 0600 "$USER_HOME/.ssh/authorized_keys"
SUDO_RULE='ALL'
if [ "$ALLOW_NOPASSWD_SUDO" -eq 1 ]; then
  SUDO_RULE='NOPASSWD: ALL'
fi
cat > "/etc/sudoers.d/90-$APP-$ADMIN_USER" <<EOF
# 仅授予明确创建的管理员完整 sudo 权限。
$ADMIN_USER ALL=(ALL:ALL) $SUDO_RULE
EOF
chmod 0440 "/etc/sudoers.d/90-$APP-$ADMIN_USER"
visudo -cf "/etc/sudoers.d/90-$APP-$ADMIN_USER" >/dev/null
if [ "$ALLOW_NOPASSWD_SUDO" -eq 0 ]; then
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
  unset ADMIN_PASSWORD
fi

info '写入 SSH 加固配置（只管理自己的 drop-in 文件）'
install -d -m 0755 /etc/ssh/sshd_config.d
# 旧版本使用 99- 前缀。OpenSSH 对大多数单值配置采用首次读取的值，
# 因此先移除本工具旧文件，再以 00- 前缀写入当前策略。
rm -f "$LEGACY_SSH_DROPIN"
cat > "$SSH_DROPIN" <<EOF
# Managed by $APP.
Port $SSH_PORT
PermitRootLogin no
AllowUsers $ADMIN_USER
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
assert_sshd_single_value permitrootlogin no
assert_sshd_single_value allowusers "$ADMIN_USER"
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
  printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\n' "$TELEGRAM_TOKEN" "$TELEGRAM_CHAT_ID" > "$CONF_DIR/telegram.env"
  chmod 0600 "$CONF_DIR/telegram.env"
  cat > "$NOTIFIER" <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
ENV_FILE=/etc/vps-security/telegram.env
[ -r "$ENV_FILE" ] || exit 0
source "$ENV_FILE"
mask_ip() {
  local ip=$1 first second
  if [[ "$ip" == *.*.*.* ]]; then
    IFS=. read -r first second _ <<<"$ip"
    printf '%s.%s.x.x' "$first" "$second"
  elif [[ "$ip" == *:* ]]; then
    IFS=: read -r first second _ <<<"$ip"
    [ -n "$first" ] || first=0
    [ -n "$second" ] || second=0
    printf '%s:%s:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx' "$first" "$second"
  else
    printf 'unknown'
  fi
}
send() {
  curl --silent --show-error --fail --connect-timeout 3 --max-time 8 \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" >/dev/null || true
}
event=$1
host=$(hostname -f 2>/dev/null || hostname)
now=$(date -u '+%Y-%m-%d %H:%M:%SZ')
case "$event" in
  login)
    [ "$PAM_SERVICE" = sshd ] && [ "$PAM_TYPE" = open_session ] || exit 0
    send "✅ SSH 公钥登录成功
主机：$host
用户：$PAM_USER
IP：$(mask_ip "$PAM_RHOST")
时间：$now"
    ;;
  ban)
    send "⛔ Fail2ban 已封禁
主机：$host
Jail：$3
IP：$(mask_ip "$2")
时间：$now"
    ;;
esac
EOF
  chmod 0700 "$NOTIFIER"
  cat > "$F2B_ACTION" <<'EOF'
[Definition]
actionban = /usr/local/sbin/vps-security-notify ban '<ip>' '<name>'
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

info '校验并启动 Fail2ban'
fail2ban-client -d >/dev/null
systemctl enable --now fail2ban
systemctl restart fail2ban
fail2ban-client ping >/dev/null
fail2ban-client status sshd

cat <<EOF

完成。请另开一个终端验证：
  ssh -p $SSH_PORT $ADMIN_USER@<你的服务器IP>
EOF
if [ "$SCHEDULE_ROLLBACK" -eq 1 ]; then
  echo "确认新登录成功后，立刻执行：sudo $CONFIRM"
  echo "若 $ROLLBACK_SECONDS 秒内没有确认，SSH drop-in 会自动回滚。"
fi
[ -n "$TELEGRAM_TOKEN" ] && echo 'Telegram 已启用：成功 SSH 公钥登录和 Fail2ban 封禁都会通知，IP 会打码。'
echo '注意：请在云厂商安全组/防火墙中先放行新的 SSH 端口。'
