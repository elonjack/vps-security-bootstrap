#!/usr/bin/env bash
# Debian 13 SSH hardening + Fail2ban + optional Telegram notifications.
set -Eeuo pipefail
IFS=$'\n\t'

readonly APP='vps-security-bootstrap'
readonly CONF_DIR='/etc/vps-security'
readonly SSH_DROPIN='/etc/ssh/sshd_config.d/99-vps-security-bootstrap.conf'
readonly F2B_JAIL='/etc/fail2ban/jail.d/sshd-vps-security.local'
readonly F2B_ACTION='/etc/fail2ban/action.d/vps-security-telegram.conf'
readonly NOTIFIER='/usr/local/sbin/vps-security-notify'
readonly CONFIRM='/usr/local/sbin/vps-security-confirm'
SSH_PORT=52022
ADMIN_USER=admin
PUBLIC_KEY=''
PUBLIC_KEY_FILE=''
IGNORE_IP=''
TELEGRAM_TOKEN=''
TELEGRAM_CHAT_ID=''
TELEGRAM_TOKEN_FILE=''
TELEGRAM_CHAT_ID_FILE=''
BANTIME=1d
ROLLBACK_SECONDS=600
SCHEDULE_ROLLBACK=1

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
  --telegram-token TOKEN       Telegram bot token（须同时提供 chat id）
  --telegram-chat-id ID        Telegram chat/group id（须同时提供 token）
  --telegram-token-file PATH   从 root 可读文件读取 token（推荐，避免出现在历史记录）
  --telegram-chat-id-file PATH 从 root 可读文件读取 chat id（推荐）
  --permanent-bans             永久封禁（不推荐，默认逐级延长至 4 周）
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
    --admin-user) need_value "$@"; ADMIN_USER=$2; shift 2 ;;
    --ssh-port) need_value "$@"; SSH_PORT=$2; shift 2 ;;
    --ignoreip) need_value "$@"; IGNORE_IP=$2; shift 2 ;;
    --telegram-token) need_value "$@"; TELEGRAM_TOKEN=$2; shift 2 ;;
    --telegram-chat-id) need_value "$@"; TELEGRAM_CHAT_ID=$2; shift 2 ;;
    --telegram-token-file) need_value "$@"; TELEGRAM_TOKEN_FILE=$2; shift 2 ;;
    --telegram-chat-id-file) need_value "$@"; TELEGRAM_CHAT_ID_FILE=$2; shift 2 ;;
    --permanent-bans) BANTIME=-1; shift ;;
    --no-rollback) SCHEDULE_ROLLBACK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done

[ "$EUID" -eq 0 ] || die '请以 root 运行：sudo bash bootstrap.sh …'
[ -r /etc/debian_version ] || die '此脚本仅面向 Debian 13。'
. /etc/os-release
[ "$ID" = debian ] && [ "$VERSION_ID" = 13 ] || die '此脚本仅支持 Debian 13。'
[[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$SSH_PORT" -le 65535 ] || die '--ssh-port 必须是 1–65535。'
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die '--admin-user 格式不正确。'
[ -z "$PUBLIC_KEY" ] || [ -z "$PUBLIC_KEY_FILE" ] || die '只能使用一种公钥传入方式。'
[ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_TOKEN_FILE" ] || die 'Telegram token 只能使用一种传入方式。'
[ -z "$TELEGRAM_CHAT_ID" ] || [ -z "$TELEGRAM_CHAT_ID_FILE" ] || die 'Telegram chat id 只能使用一种传入方式。'
[ -z "$TELEGRAM_TOKEN_FILE" ] || { [ -r "$TELEGRAM_TOKEN_FILE" ] || die '无法读取 Telegram token 文件。'; TELEGRAM_TOKEN=$(head -n 1 "$TELEGRAM_TOKEN_FILE"); }
[ -z "$TELEGRAM_CHAT_ID_FILE" ] || { [ -r "$TELEGRAM_CHAT_ID_FILE" ] || die '无法读取 Telegram chat id 文件。'; TELEGRAM_CHAT_ID=$(head -n 1 "$TELEGRAM_CHAT_ID_FILE"); }
[ -n "$TELEGRAM_TOKEN" ] && [ -z "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'
[ -z "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && die 'Telegram token 和 chat id 必须同时提供。'

if [ -n "$PUBLIC_KEY_FILE" ]; then
  [ -r "$PUBLIC_KEY_FILE" ] || die "无法读取公钥文件：$PUBLIC_KEY_FILE"
  PUBLIC_KEY=$(grep -E '^(ssh-(ed25519|rsa|ecdsa)|sk-ssh-ed25519)' "$PUBLIC_KEY_FILE" | head -n 1 || true)
fi
[ -n "$PUBLIC_KEY" ] || die '请用 --public-key-file 提供 .pub 公钥。'
printf '%s\n' "$PUBLIC_KEY" | ssh-keygen -l -f - >/dev/null 2>&1 || die '提供的不是有效 SSH 公钥。'
command -v sshd >/dev/null 2>&1 || die '未找到 sshd；请先安装 openssh-server。'

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$CONF_DIR/backups/$STAMP"
ROLLBACK_SCRIPT="$CONF_DIR/rollback-ssh-$STAMP.sh"
mkdir -p "$BACKUP_DIR"
chmod 700 "$CONF_DIR" "$BACKUP_DIR"
backup_if_exists() { [ -e "$1" ] && cp -a "$1" "$BACKUP_DIR/$2" || true; }
backup_if_exists "$SSH_DROPIN" ssh-dropin.before
backup_if_exists /etc/pam.d/sshd pam-sshd.before
backup_if_exists "$F2B_JAIL" fail2ban-jail.before
backup_if_exists "$F2B_ACTION" fail2ban-action.before

info '安装 Debian 官方软件包（OpenSSH、Fail2ban、nftables、curl）'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openssh-server fail2ban nftables curl sudo libpam-modules

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
cat > "/etc/sudoers.d/90-$APP-$ADMIN_USER" <<EOF
# SSH 公钥持有者可以成为 root；不设置本地密码。
$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "/etc/sudoers.d/90-$APP-$ADMIN_USER"
visudo -cf "/etc/sudoers.d/90-$APP-$ADMIN_USER" >/dev/null

info '写入 SSH 加固配置（只管理自己的 drop-in 文件）'
install -d -m 0755 /etc/ssh/sshd_config.d
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

info '校验 SSH 配置'
sshd -t
PORTS=$(sshd -T | awk '$1 == "port" {print $2}')
[ "$PORTS" = "$SSH_PORT" ] || die "SSH 实际端口并非唯一的 $SSH_PORT（得到：$PORTS）；脚本没有重载 SSH。"

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
sshd -t && systemctl reload ssh
EOF
  chmod 0700 "$ROLLBACK_SCRIPT"
  systemd-run --quiet --unit=vps-security-ssh-rollback --on-active="$ROLLBACK_SECONDS"s "$ROLLBACK_SCRIPT"
  cat > "$CONFIRM" <<EOF
#!/usr/bin/env bash
set -euo pipefail
systemctl cancel vps-security-ssh-rollback.service 2>/dev/null || true
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
