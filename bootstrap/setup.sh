#!/usr/bin/env bash
#
# m-ino.jp OS初期設定スクリプト
#
# 実行方法は2通り:
#   A. さくらのスタートアップスクリプト経由（推奨。bootstrap/startup-script.sh を参照）
#   B. さくらのコンソールから手動:
#        sudo SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
#             bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/m-ino-jp/main/bootstrap/setup.sh)"
#
# 冪等。何度実行しても同じ結果になる。

set -euo pipefail

ADMIN_USER="${ADMIN_USER:-ino}"
HOSTNAME_FQDN="${HOSTNAME_FQDN:-m-ino.jp}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"

log() { printf '\n=== %s ===\n' "$*"; }

if [[ $EUID -ne 0 ]]; then
  echo "rootで実行してください" >&2
  exit 1
fi

. /etc/os-release
log "OS: ${PRETTY_NAME}"

# ---------------------------------------------------------------------------
log "1. ホスト名とタイムゾーン"
# ---------------------------------------------------------------------------
hostnamectl set-hostname "${HOSTNAME_FQDN}"
timedatectl set-timezone Asia/Tokyo
# ロケールは英語のまま。日本語化するとログが読みづらくなり、
# 検索でヒットする情報とも食い違うため。

# ---------------------------------------------------------------------------
log "2. パッケージ更新と基本ツール"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y \
  ca-certificates curl gnupg git jq \
  ufw fail2ban unattended-upgrades needrestart \
  htop ncdu

# ---------------------------------------------------------------------------
log "3. swap ${SWAP_SIZE_GB}GB"
# ---------------------------------------------------------------------------
# メモリ2GBに対して大きめに確保する。常用させるためではなく、
# 一時的なメモリスパイクでOOM Killerに殺されるのを防ぐための保険。
if [[ ! -f /swapfile ]]; then
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
else
  echo "/swapfile は既に存在するのでスキップ"
fi

if ! grep -q '^/swapfile' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# swappiness を下げ、可能な限り物理メモリを使わせる。
install -m 644 -D /dev/stdin /etc/sysctl.d/99-m-ino-jp.conf <<'EOF'
# swapは緊急時の保険。平常時はできるだけ物理メモリを使う
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# SYN flood 対策
net.ipv4.tcp_syncookies = 1
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------------------
log "4. SSH公開鍵の配置"
# ---------------------------------------------------------------------------
# sshdを固める前に鍵を置く。順序を逆にすると締め出される。
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
    usermod -aG sudo "${ADMIN_USER}"
  fi
  user_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  install -d -m 700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "${user_home}/.ssh"
  install -m 600 -o "${ADMIN_USER}" -g "${ADMIN_USER}" /dev/stdin \
    "${user_home}/.ssh/authorized_keys" <<EOF
${SSH_PUBLIC_KEY}
EOF
  echo "公開鍵を ${user_home}/.ssh/authorized_keys に配置した"
else
  echo "警告: SSH_PUBLIC_KEY が空。さくらのコントロールパネルで登録済みか確認すること" >&2
fi

# ---------------------------------------------------------------------------
log "5. sshd の設定"
# ---------------------------------------------------------------------------
# 元の sshd_config は書き換えず drop-in を置く。
# OSアップグレードで元ファイルが更新されても設定が残る。
install -m 644 -D /dev/stdin /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${ADMIN_USER}
X11Forwarding no
EOF

# 設定の文法チェック。失敗したら適用せず止める。
sshd -t
systemctl reload ssh || systemctl reload sshd

# 締め出されてもさくらのコンソール（シリアルコンソール）からは
# パスワードでログインできる。ino のパスワードは必ず控えておくこと。

# ---------------------------------------------------------------------------
log "6. ファイアウォール（ufw）"
# ---------------------------------------------------------------------------
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'HTTP (Caddy)'
ufw allow 443/tcp  comment 'HTTPS (Caddy)'
ufw --force enable

# 重要: Dockerが -p で公開したポートはufwを迂回する。
# 対策として、80/443を公開するのはCaddyコンテナだけに限定する運用を守ること。

# ---------------------------------------------------------------------------
log "7. fail2ban"
# ---------------------------------------------------------------------------
# Ubuntu 24.04 は sshd のログを journald に出すため backend を systemd にする。
install -m 644 -D /dev/stdin /etc/fail2ban/jail.d/99-m-ino-jp.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
log "8. 自動セキュリティアップデート"
# ---------------------------------------------------------------------------
# 深夜の数分の停止は許容する方針。再起動を自動化する。
install -m 644 -D /dev/stdin /etc/apt/apt.conf.d/52-m-ino-jp-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

install -m 644 -D /dev/stdin /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# needrestart が対話プロンプトを出すと自動更新が止まるので自動再起動にする
install -m 644 -D /dev/stdin /etc/needrestart/conf.d/99-m-ino-jp.conf <<'EOF'
$nrconf{restart} = 'a';
EOF

systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
log "9. ログの永続化とローテーション"
# ---------------------------------------------------------------------------
install -m 644 -D /dev/stdin /etc/systemd/journald.conf.d/99-m-ino-jp.conf <<'EOF'
# 再起動をまたいでログを残す。200GBのSSDに対して500MBは十分小さい。
Storage=persistent
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
log "10. Docker と Docker Compose"
# ---------------------------------------------------------------------------
# Ubuntu標準のdocker.ioではなくDocker公式リポジトリを使う。
# compose v2 プラグインが公式リポジトリ側にしかないため。
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

install -m 644 -D /dev/stdin /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

install -m 644 -D /dev/stdin /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "default-address-pools": [
    { "base": "172.20.0.0/16", "size": 24 }
  ]
}
EOF
systemctl enable --now docker
systemctl restart docker

# docker グループは実質root権限に等しい。単一管理者のサーバなので許容する。
usermod -aG docker "${ADMIN_USER}"

# コンテナ間を繋ぐ共有ネットワーク。Caddyと各サービスがここで出会う。
docker network inspect edge >/dev/null 2>&1 || docker network create edge

# ---------------------------------------------------------------------------
log "11. ディレクトリと通知スクリプト"
# ---------------------------------------------------------------------------
install -d -m 755 -o "${ADMIN_USER}" -g "${ADMIN_USER}" /srv/m-ino-jp
install -d -m 755 -o "${ADMIN_USER}" -g "${ADMIN_USER}" /srv/data
install -d -m 750 /etc/m-ino-jp

# Discord Webhook への通知。メールサーバを立てない代わりの仕組み。
install -m 755 -D /dev/stdin /usr/local/bin/notify-discord <<'EOF'
#!/usr/bin/env bash
# 使い方: notify-discord "メッセージ"
#   systemd からは OnFailure= 経由で呼ぶ
set -euo pipefail
[[ -f /etc/m-ino-jp/notify.env ]] || exit 0
. /etc/m-ino-jp/notify.env
[[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || exit 0

message="${1:-(メッセージなし)}"
payload=$(jq -Rn --arg c "[$(hostname)] ${message}" '{content: $c}')
curl -fsS -H 'Content-Type: application/json' -d "${payload}" \
  "${DISCORD_WEBHOOK_URL}" >/dev/null
EOF

if [[ ! -f /etc/m-ino-jp/notify.env ]]; then
  install -m 600 -D /dev/stdin /etc/m-ino-jp/notify.env <<'EOF'
# Discord の Webhook URL をここに設定する。このファイルはGit管理外。
DISCORD_WEBHOOK_URL=
EOF
fi

# ---------------------------------------------------------------------------
log "完了"
# ---------------------------------------------------------------------------
cat <<EOF

初期設定が完了しました。次にやること:

  1. ローカルから SSH で接続できることを確認
       ssh ${ADMIN_USER}@<VPSのIP>

  2. ${ADMIN_USER} のパスワードを設定し、1Password に保管する
     （さくらのコンソールからの緊急ログイン用）
       sudo passwd ${ADMIN_USER}

  3. /etc/m-ino-jp/notify.env に Discord Webhook URL を設定
       sudo vi /etc/m-ino-jp/notify.env
       notify-discord "テスト通知"

  4. DNS の A レコードを VPS の IP に向ける

  5. リポジトリを /srv/m-ino-jp に clone し、Caddy から構築を始める

現在の状態:
EOF
free -h
echo
ufw status verbose
