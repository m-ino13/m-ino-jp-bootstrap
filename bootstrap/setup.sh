#!/usr/bin/env bash
#
# m-ino.jp OS初期設定スクリプト
#
# 実行方法は2通り:
#   A. さくらのスタートアップスクリプト経由（推奨。bootstrap/startup-script.sh を参照）
#   B. さくらのコンソールから手動:
#        sudo SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
#             bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-ino13/m-ino-jp-bootstrap/main/bootstrap/setup.sh)"
#
#      取得元は公開用リポジトリ（m-ino-jp-bootstrap）。本体（m-ino-jp）は非公開で、
#      raw.githubusercontent.com から認証なしには取得できない。
#
# 冪等。何度実行しても同じ結果になる。

set -euo pipefail

ADMIN_USER="${ADMIN_USER:-ino}"
# 公開ドメイン（m-ino.jp）と同じ文字列にしないこと。VPSのホスト名と
# 公開ドメインが一致すると、systemd-resolvedがそのドメイン名への問い合わせを
# 実DNSに問い合わせずローカル合成応答（127.0.1.1）で返すようになり、コンテナ
# 内からのサーバー間通信（OIDCのトークン交換など）が失敗する
# （docs/adr/0013-auth-domain-dns-loopback.md）。ドット無しの文字列にしておけば
# どのDNSレコードとも一致しないため、この衝突が起こらない。
HOSTNAME_FQDN="${HOSTNAME_FQDN:-m-ino-jp}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"

# ブート直後は cloud-init や自動更新と dpkg のロックが競合する。すぐ諦めずに待つ。
APT_OPTS=(-o DPkg::Lock::Timeout=300)

log() { printf '\n=== %s ===\n' "$*"; }

# 後で読み飛ばされないよう、警告は最後にまとめて再掲する。
WARNINGS=()
warn() {
  WARNINGS+=("$*")
  printf '警告: %s\n' "$*" >&2
}

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

# /etc/hosts を揃えないと sudo のたびに "unable to resolve host" が出る。
# 該当行を消してから足すことで、何度実行しても1行だけになる。
short_hostname="${HOSTNAME_FQDN%%.*}"
sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
printf '127.0.1.1\t%s %s\n' "${HOSTNAME_FQDN}" "${short_hostname}" >> /etc/hosts

timedatectl set-timezone Asia/Tokyo
# ロケールは英語のまま。日本語化するとログが読みづらくなり、
# 検索でヒットする情報とも食い違うため。

# ---------------------------------------------------------------------------
log "2. パッケージ更新と基本ツール"
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" -y upgrade
apt-get "${APT_OPTS[@]}" install -y \
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
else
  echo "/swapfile は既に存在するのでスキップ"
fi

# 有効化は存在チェックとは別に行う。ファイルはあるが swapon されていない
# 状態（fstab を書く前に落ちた場合など）でも回復できるようにするため。
swapon --show=NAME --noheadings | grep -qx '/swapfile' || swapon /swapfile

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
log "4. 管理ユーザーとSSH公開鍵"
# ---------------------------------------------------------------------------
# sshdを固める前にユーザーと鍵を用意する。順序を逆にすると締め出される。
if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${ADMIN_USER}"
fi

# 既存ユーザー（さくらの標準OSインストールが作ったもの）でも所属を保証する。
# ユーザー作成ブロックの中に置くと、既存ユーザーのときに実行されない。
usermod -aG sudo "${ADMIN_USER}"

user_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
admin_group="$(id -gn "${ADMIN_USER}")"
admin_authorized_keys="${user_home}/.ssh/authorized_keys"

# パスワードが無いと sudo が使えず、締め出されたときのコンソールログインもできない。
# 復旧経路が消えるので、状態を確認して警告する。
if [[ "$(passwd -S "${ADMIN_USER}" | awk '{print $2}')" != "P" ]]; then
  warn "${ADMIN_USER} にパスワードが設定されていない。sudo とコンソールからの緊急ログインができない。root のうちに 'passwd ${ADMIN_USER}' を実行すること"
fi

if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
  install -d -m 700 -o "${ADMIN_USER}" -g "${admin_group}" "${user_home}/.ssh"

  # 追記ではなく上書きする（冪等性のため）。ここで渡した鍵だけが残り、
  # さくらのコントロールパネルで登録した鍵や2本目の鍵は消える。
  # 消える内容は setup.log に残しておく（公開鍵なのでログに出しても問題ない）。
  if [[ -s "${admin_authorized_keys}" ]]; then
    echo "--- 上書き前の authorized_keys ---"
    cat "${admin_authorized_keys}"
    echo "----------------------------------"
  fi

  install -m 600 -o "${ADMIN_USER}" -g "${admin_group}" /dev/stdin \
    "${admin_authorized_keys}" <<EOF
${SSH_PUBLIC_KEY}
EOF
  echo "公開鍵を ${admin_authorized_keys} に配置した"
else
  warn "SSH_PUBLIC_KEY が空。既存の ${admin_authorized_keys} をそのまま使う"
fi

# プロンプトの \u@\h（USER@ホスト名）部分を目立つ色に変える。
# リモート(VPS)で作業していることを一目で分かるようにし、ローカル環境との
# 取り違えを防ぐのが目的。xterm-256color の256色パレット206番(#ff5fdf)。
#
# /etc/skel/.bashrc 由来の PS1 は \[\033[01;32m\]\u@\h\[\033[00m\]:... という形で、
# 01;32m(緑) がこの部分だけの色指定。この文字列は行内で一度しか出てこないため、
# 置換のみで狙った箇所だけを変えられる。置換後は 01;32m が無くなるので、
# 再実行しても何も起きない(冪等)。
admin_bashrc="${user_home}/.bashrc"
if [[ -f "${admin_bashrc}" ]]; then
  sed -i 's/01;32m/38;5;206m/' "${admin_bashrc}"
fi

# ---------------------------------------------------------------------------
log "5. sshd の設定"
# ---------------------------------------------------------------------------
# 元の sshd_config は書き換えず drop-in を置く。
# OSアップグレードで元ファイルが更新されても設定が残る。
#
# ファイル名が 01- なのは、sshd が「最初に見つかった値」を採用し、
# Include が辞書順に読まれるため。cloud-init が置く 50-cloud-init.conf に
# PasswordAuthentication yes が入っていることがあり、99- では負けて黙って無視される。
rm -f /etc/ssh/sshd_config.d/99-hardening.conf   # 旧版の名残を掃除する

sshd_hardening_conf=/etc/ssh/sshd_config.d/01-hardening.conf

if [[ -s "${admin_authorized_keys}" ]]; then
  install -m 644 -D /dev/stdin "${sshd_hardening_conf}" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers ${ADMIN_USER}
X11Forwarding no
EOF

  # sshd -t は privilege separation 用の /run/sshd が無いと失敗する。
  # このディレクトリは ssh.service の RuntimeDirectory= が作るものだが、
  # Ubuntu 24.04 の既定は ssh.socket による socket activation なので、
  # 初回の接続があるまで ssh.service は起動せずディレクトリも存在しない。
  # /run は tmpfs で再起動のたびに消えるため、起動直後に走るこのスクリプトからは
  # 常に存在しない。無ければ作る（ssh.service が作るものと同じ属性）。
  install -d -m 0755 -o root -g root /run/sshd

  # 文法チェックに落ちたら drop-in を残さない。
  # 残すと、次にsshdが再起動したときに起動しなくなる。
  if ! sshd -t; then
    rm -f "${sshd_hardening_conf}"
    echo "sshd の設定が不正だったため、適用せずに中止した" >&2
    exit 1
  fi

  # Ubuntu 24.04 は既定で ssh.socket による socket activation。
  # その場合 ssh.service は動いていないので reload は失敗するが、
  # 接続のたびに sshd が起動して設定を読み直すため reload 自体が不要。
  if systemctl is-active --quiet ssh.socket; then
    echo "ssh.socket による socket activation。次の接続から新しい設定が使われる"
  elif ! systemctl reload ssh 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || warn "sshd の reload に失敗した。手動で確認すること"
  fi

  # drop-in の優先順位を間違えると設定が黙って無視されるため、実効値を出す。
  echo "--- sshd の実効設定 ---"
  sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|allowusers|kbdinteractiveauthentication)' || true
  echo "-----------------------"
else
  rm -f "${sshd_hardening_conf}"
  warn "authorized_keys が空のため sshd のハードニングをスキップした。鍵が無い状態でパスワード認証を無効化すると誰もログインできなくなる"
fi

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
#
# 注意: reset はDockerが入れたiptablesのチェインも巻き込む。この後の手順10で
# dockerを再起動するので通しで実行する分には問題ないが、この節だけを
# 単独で流し直したときは `systemctl restart docker` も実行すること。

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
systemctl enable fail2ban
# 既に起動している場合、enable --now では設定が読み直されないので restart する。
systemctl restart fail2ban

# ---------------------------------------------------------------------------
log "8. 自動セキュリティアップデート"
# ---------------------------------------------------------------------------
# 深夜の数分の停止は許容する方針。再起動を自動化する。
#
# 更新取得(apt-daily.timer) → 適用(apt-daily-upgrade.timer) → 再起動 の順に
# 時刻を早朝へずらす。unattended-upgrade コマンドは apt-get update 相当の
# キャッシュ更新を自分では行わず /var/lib/apt/lists/ をそのまま使うため、
# 適用側だけずらしても取得側(デフォルトは6,18:00±12hとかなり緩い)が
# 追いつかないことがある。両方揃えて早める。
install -m 644 -D /dev/stdin /etc/apt/apt.conf.d/52-m-ino-jp-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

install -m 644 -D /dev/stdin /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# apt-daily.timer（更新取得）を 03:00±10分 に。OnCalendar= を空にしてから
# 上書きしないと元ユニットの値に追加されてしまう点に注意。
install -m 644 -D /dev/stdin /etc/systemd/system/apt-daily.timer.d/99-m-ino-jp.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=10m
EOF

# apt-daily-upgrade.timer（適用）を 03:20±15分 に。取得(03:00〜03:10完了見込み)
# との間に10分の余裕を置く。
install -m 644 -D /dev/stdin /etc/systemd/system/apt-daily-upgrade.timer.d/99-m-ino-jp.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:20
RandomizedDelaySec=15m
EOF

systemctl daemon-reload
systemctl restart apt-daily.timer apt-daily-upgrade.timer

# needrestart が対話プロンプトを出すと自動更新が止まるので自動再起動にする
install -m 644 -D /dev/stdin /etc/needrestart/conf.d/99-m-ino-jp.conf <<'EOF'
$nrconf{restart} = 'a';
EOF

systemctl enable --now unattended-upgrades

# ---------------------------------------------------------------------------
log "9. ログの永続化とローテーション"
# ---------------------------------------------------------------------------
# [Journal] セクションヘッダは必須。無いと全行が黙って無視される。
install -m 644 -D /dev/stdin /etc/systemd/journald.conf.d/99-m-ino-jp.conf <<'EOF'
[Journal]
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

apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" install -y docker-ce docker-ce-cli containerd.io \
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
install -d -m 755 -o "${ADMIN_USER}" -g "${admin_group}" /srv/m-ino-jp
install -d -m 755 -o "${ADMIN_USER}" -g "${admin_group}" /srv/data

# 書き込みはrootだけ、読み取りは管理ユーザーにも許す。
# notify-discord を ino がそのまま実行できるようにするため。
install -d -m 750 -o root -g "${admin_group}" /etc/m-ino-jp

# Discord Webhook への通知。メールサーバを立てない代わりの仕組み。
install -m 755 -D /dev/stdin /usr/local/bin/notify-discord <<'EOF'
#!/usr/bin/env bash
# 使い方: notify-discord "メッセージ"
#   systemd からは notify.d/10-discord 経由（OnFailure=notify@%n.service）で呼ばれる
set -euo pipefail

if [[ ! -r /etc/m-ino-jp/notify.env ]]; then
  echo "notify-discord: /etc/m-ino-jp/notify.env が無いか読めない" >&2
  exit 1
fi
. /etc/m-ino-jp/notify.env

if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  echo "notify-discord: DISCORD_WEBHOOK_URL が未設定" >&2
  exit 1
fi

message="${1:-(メッセージなし)}"
payload=$(jq -Rn --arg c "[$(hostname)] ${message}" '{content: $c}')
curl -fsS -H 'Content-Type: application/json' -d "${payload}" \
  "${DISCORD_WEBHOOK_URL}" >/dev/null
EOF

# Brevo Transactional Email API への通知。notify-discordと対称的な構成
# （docs/adr/0030-notify-email-brevo.md）。
install -m 755 -D /dev/stdin /usr/local/bin/notify-email <<'EOF'
#!/usr/bin/env bash
# 使い方: notify-email "メッセージ"
set -euo pipefail

if [[ ! -r /etc/m-ino-jp/notify.env ]]; then
  echo "notify-email: /etc/m-ino-jp/notify.env が無いか読めない" >&2
  exit 1
fi
. /etc/m-ino-jp/notify.env

if [[ -z "${BREVO_API_KEY:-}" || -z "${BREVO_NOTIFY_FROM:-}" || -z "${BREVO_NOTIFY_TO:-}" ]]; then
  echo "notify-email: BREVO_API_KEY / BREVO_NOTIFY_FROM / BREVO_NOTIFY_TO が未設定" >&2
  exit 1
fi

message="${1:-(メッセージなし)}"
payload=$(jq -n \
  --arg from "${BREVO_NOTIFY_FROM}" \
  --arg to "${BREVO_NOTIFY_TO}" \
  --arg subj "[$(hostname)] m-ino.jp 通知" \
  --arg text "${message}" \
  '{sender:{email:$from}, to:[{email:$to}], subject:$subj, textContent:$text}')

curl -fsS -X POST "https://api.brevo.com/v3/smtp/email" \
  -H "api-key: ${BREVO_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${payload}" >/dev/null
EOF

# OnFailure= はユニット名しか受け取れないため、notifyディスパッチャを包む
# 汎用テンプレートユニットを置く。使う側は OnFailure=notify@%n.service と書く
# （個別チャンネル直呼びのnotify-discord@.serviceは廃止。docs/adr/0030）。
install -m 644 -D /dev/stdin /etc/systemd/system/notify@.service <<'EOF'
[Unit]
Description=Notification for %i

[Service]
Type=oneshot
ExecStart=/usr/local/bin/notify "%i の実行に失敗しました"
EOF
rm -f /etc/systemd/system/notify-discord@.service
systemctl daemon-reload

# 汎用の通知エントリポイント。/etc/m-ino-jp/notify.d/ 配下の実行可能ファイルを
# 全て呼ぶだけで、宛先を知らない。スキャン結果の通知のように「失敗ではないが
# 知らせたい」用途向け（OnFailure= は失敗時専用でこれには使えない）。
# 通知経路を増やすとき（将来メールサーバを立てた場合など）は、このディレクトリに
# スクリプトを追加するだけでよく、呼び出し側は変更不要。
install -m 755 -D /dev/stdin /usr/local/bin/notify <<'EOF'
#!/usr/bin/env bash
# 使い方: notify "メッセージ"
set -euo pipefail

msg="${1:?メッセージを指定してください}"
shopt -s nullglob
channels=(/etc/m-ino-jp/notify.d/*)

if [[ ${#channels[@]} -eq 0 ]]; then
  echo "notify: /etc/m-ino-jp/notify.d/ にチャンネルが無い" >&2
  exit 1
fi

status=0
for channel in "${channels[@]}"; do
  [[ -x "${channel}" ]] || continue
  "${channel}" "${msg}" || { echo "notify: ${channel} が失敗しました" >&2; status=1; }
done
exit "${status}"
EOF

install -d -m 750 -o root -g "${admin_group}" /etc/m-ino-jp/notify.d
install -m 750 -o root -g "${admin_group}" -D /dev/stdin /etc/m-ino-jp/notify.d/10-discord <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/notify-discord "$@"
EOF
install -m 750 -o root -g "${admin_group}" -D /dev/stdin /etc/m-ino-jp/notify.d/20-email <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/notify-email "$@"
EOF

if [[ ! -f /etc/m-ino-jp/notify.env ]]; then
  install -m 640 -o root -g "${admin_group}" -D /dev/stdin /etc/m-ino-jp/notify.env <<'EOF'
# Discord の Webhook URL をここに設定する。このファイルはGit管理外。
DISCORD_WEBHOOK_URL=
# Brevo Transactional Email API（notify-email用）。docs/66-brevo-service-integration.md 2-4。
BREVO_API_KEY=
BREVO_NOTIFY_FROM=notify@send.m-ino.jp
BREVO_NOTIFY_TO=
EOF
else
  # 既存の値は残したまま、権限だけ揃える
  chown root:"${admin_group}" /etc/m-ino-jp/notify.env
  chmod 640 /etc/m-ino-jp/notify.env
fi

# ---------------------------------------------------------------------------
log "完了"
# ---------------------------------------------------------------------------
cat <<EOF

初期設定が完了しました。次にやること:

  1. ローカルから SSH で接続できることを確認
       ssh ${ADMIN_USER}@<VPSのIP>
     （このスクリプトが配置した鍵だけが有効。他の鍵は上書きで消えている）

  2. ${ADMIN_USER} のパスワードが設定されているか確認する
     （さくらのコンソールからの緊急ログインと sudo に必要）
       passwd -S ${ADMIN_USER}     # 2列目が P なら設定済み
       sudo passwd ${ADMIN_USER}   # P でなければ設定する

  3. /etc/m-ino-jp/notify.env に Discord Webhook URL を設定
       sudo vi /etc/m-ino-jp/notify.env
       notify-discord "テスト通知"
       notify "テスト通知（notify.d 経由）"

  4. DNS の A レコードを VPS の IP に向ける

  5. リポジトリを /srv/m-ino-jp に clone し、Caddy から構築を始める
     （本体リポジトリは非公開。deploy key が要る。docs/10-os-setup.md の手順8）

現在の状態:
EOF
free -h
echo
ufw status verbose

if ((${#WARNINGS[@]} > 0)); then
  printf '\n=== 警告 (%d件) ===\n' "${#WARNINGS[@]}"
  printf -- '- %s\n' "${WARNINGS[@]}"
fi
