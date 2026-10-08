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
#
# 稼働中のVPSへ「読み取り専用ユーザー claude」だけを足したいときは、全体を
# 流し直さず ONLY_CLAUDE_USER=1 を付ける（docs/94-claude-readonly-user.md）:
#   sudo ONLY_CLAUDE_USER=1 CLAUDE_SSH_PUBLIC_KEY='ssh-ed25519 AAAA...' \
#        bash /srv/m-ino-jp/bootstrap/setup.sh
#
# 同じく、通知の送信スクリプト（notify-discord / notify-email）だけを入れ直したい
# ときは ONLY_NOTIFY=1（docs/95-process-argv-hardening.md 手順4）:
#   sudo ONLY_NOTIFY=1 bash /srv/m-ino-jp/bootstrap/setup.sh

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

# Claude Code 用の読み取り専用ユーザー（docs/adr/0057-claude-readonly-user.md）。
# sudo にも docker グループにも入れない。公開鍵は公開情報なのでここに渡してよい。
CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_SSH_PUBLIC_KEY="${CLAUDE_SSH_PUBLIC_KEY:-}"
# 1なら claude ユーザーの節だけを実行して終了する（稼働中VPSへの追加用）。
ONLY_CLAUDE_USER="${ONLY_CLAUDE_USER:-0}"
# 1なら notify-discord / notify-email の配置だけを実行して終了する（稼働中VPSへの入れ直し用）。
ONLY_NOTIFY="${ONLY_NOTIFY:-0}"

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

# sshd の設定（drop-in）を、稼働中の sshd に反映する。
# Ubuntu 24.04 の ssh.socket は「最初の接続で ssh.service を起動する」だけで、起動した
# sshd は常駐し続ける。接続のたびに設定を読み直すわけではないので、稼働中なら reload
# しないと drop-in が効かない（reload は既存セッションを切らない）。未起動なら、
# 起動時に新しい設定が読まれるので何もしなくてよい。
reload_sshd() {
  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
      || warn "sshd の reload に失敗した。手動で確認すること（sudo systemctl reload ssh）"
    echo "sshd を reload した"
  else
    echo "ssh.service は未起動（socket activation で初回接続待ち）。起動時に新しい設定が読まれる"
  fi
}

print_warnings() {
  if ((${#WARNINGS[@]} > 0)); then
    printf '\n=== 警告 (%d件) ===\n' "${#WARNINGS[@]}"
    printf -- '- %s\n' "${WARNINGS[@]}"
  fi
}

# ---------------------------------------------------------------------------
# needrestart の drop-in（自動再起動 + インタプリタのスキャン無効化）
# ---------------------------------------------------------------------------
# 通しの実行（8節）と setup_claude_user（ONLY_CLAUDE_USER=1 では8節が流れない）の
# 両方から呼ぶ。drop-in は全文を書き直す（追記ではない）ので、行を足すときはここに足す。
#   restart = 'a'      : 対話プロンプトを出すと自動更新が止まるので、自動再起動にする
#   interpscan = 0     : 他ユーザーが置いたスクリプトを needrestart が解釈実行しない
#                        ようにする（docs/adr/0060 決定5。needrestart の過去のCVEは
#                        この経路だった。導入済みの版は修正済みだが、使わない機能は切る）
write_needrestart_conf() {
  install -m 644 -D /dev/stdin /etc/needrestart/conf.d/99-m-ino-jp.conf <<'EOF'
$nrconf{restart} = 'a';
$nrconf{interpscan} = 0;
EOF
}

# ---------------------------------------------------------------------------
# claude ユーザーの封じ込め（docs/adr/0060-claude-containment.md）
# ---------------------------------------------------------------------------
# ADR 0057 は「ファイル権限」で読み取り専用を担保した。ここはそれ以外（居座り・
# 鍵の書き換え・ネットワーク・資源）を塞ぐ関数群で、すべて setup_claude_user から
# 呼ばれる。claude の鍵が漏れた場合の被害を、攻撃者が claude を名乗って入れる範囲
# （状況確認だけ）に閉じ込めるのが目的。

# 副作用の前に、CLAUDE_USER が「作ってよい／触ってよいユーザー」かを確かめる。
# 変数の打ち間違いで ino や root を指すと、setup_claude_user は sudo・docker の
# グループから外し、authorized_keys を上書きしてしまう（ADR 0060 決定4）。
guard_claude_user() {
  if [[ "${CLAUDE_USER}" == "${ADMIN_USER}" || "${CLAUDE_USER}" == root ]]; then
    echo "CLAUDE_USER=${CLAUDE_USER} は管理ユーザー（${ADMIN_USER}）または root と同じ。中止する" >&2
    exit 1
  fi
  if id -u "${CLAUDE_USER}" >/dev/null 2>&1; then
    local u status
    u="$(id -u "${CLAUDE_USER}")"
    if ((u < 1000)); then
      echo "${CLAUDE_USER} の UID が ${u}（1000未満。システムユーザー）。中止する" >&2
      exit 1
    fi
    # P はパスワードが設定されている状態。claude は --disabled-password で作るので L になる。
    # P なら、人間が使っているアカウントを指している可能性が高い。
    status="$(passwd -S "${CLAUDE_USER}" | awk '{print $2}')"
    if [[ "${status}" == P ]]; then
      echo "${CLAUDE_USER} にはパスワードが設定されている（passwd -S: P）。人間のアカウントの可能性があるので中止する" >&2
      exit 1
    fi
  fi
}

# claude のホームを root の所有にする（ADR 0060 決定3）。claude 自身が authorized_keys や
# .bashrc を書き換えて、restrict を外したり鍵を足したり、次のログインで何かを走らせたり
# できないようにする。鍵の変数が空のときも毎回流す（所有者の是正は鍵の有無と無関係）。
#
# 順序に意味がある。root が claude 所有のディレクトリの中で操作すると、claude が
# シンボリックリンクに差し替えて root に任意のファイルを書かせられる。そのため、
# (1)ホーム自体 → (2)直下のエントリ → (3)それより深い所、の順に root へ移す。
# (2)の後は、直下のディレクトリ（.ssh 等）の中のエントリを claude が差し替えられない。
lock_claude_home() {
  local home="$1"
  if [[ ! "${home}" =~ ^/home/[^/]+$ || ! -d "${home}" ]]; then
    echo "claude のホームが想定外のパス: '${home}'（/home/<名前> のはず）" >&2
    exit 1
  fi
  chown root:"${CLAUDE_USER}" "${home}"
  chmod 750 "${home}"
  # ~/.cache は claude が書ける場所として残っていたもの。使わせないので消す。
  rm -rf "${home:?}/.cache"
  find "${home}" -mindepth 1 -maxdepth 1 -exec chown -h root:root {} +
  # 居座りの足場になるのでシンボリックリンクは持たせない。
  find "${home}" -xdev -type l -delete
  find "${home}" -xdev -mindepth 2 -exec chown -h root:root {} +
  find "${home}" -xdev ! -type l -exec chmod go-w {} +

  # root の所有にしただけでは、claude が過去に仕込んだ中身がそのまま残る。
  # ログイン時に読まれるファイルは /etc/skel から入れ直し、読まれうる他の名前は消す。
  local f
  for f in .bashrc .profile .bash_logout; do
    if [[ -f "/etc/skel/${f}" ]]; then
      install -m 644 -o root -g root "/etc/skel/${f}" "${home}/${f}"
    else
      rm -f "${home:?}/${f}"
    fi
  done
  rm -f "${home:?}/.bash_profile" "${home:?}/.bash_login" "${home:?}/.pam_environment"

  # ~/.ssh: authorized_keys 以外は消す（authorized_keys2 など、sshd が読みうる別名を
  # 過去に置かれていても残さない）。sshd の StrictModes は root 所有を受け付ける。
  if [[ -d "${home}/.ssh" ]]; then
    chmod 755 "${home}/.ssh"
    find "${home}/.ssh" -mindepth 1 ! -name authorized_keys -delete
    if [[ -f "${home}/.ssh/authorized_keys" ]]; then
      chmod 644 "${home}/.ssh/authorized_keys"
    fi
  fi

  # リポジトリ（/srv/m-ino-jp）は ino の所有なので、claude が git を使うと
  # "dubious ownership" で拒否される。~/.gitconfig に、このパスだけを許可する
  # （'*' にはしない）。権限昇格にはならない: claude はリポジトリに書けず、
  # ino 所有の設定が下位の claude 権限で読まれる向き。VPS が取り込み済みのコミットと、
  # サーバ上の直接編集（git status）を claude が確認できるようにするため。
  # root が書く（claude は書き換えられない）。作り直すので何度流しても1行のまま（冪等）。
  if command -v git >/dev/null 2>&1; then
    rm -f "${home:?}/.gitconfig"
    git config --file "${home}/.gitconfig" --replace-all safe.directory /srv/m-ino-jp
    chown root:root "${home}/.gitconfig"
    chmod 644 "${home}/.gitconfig"
  fi
}

# crontab を ino と root だけにする（ADR 0060 決定2）。cron のジョブは pam_systemd を
# 通らず cron.service（上限なし）で動くので、user-<UID>.slice の上限を外れる。
# /etc/cron.allow があると、載っていないユーザーの crontab は動かなくなる。
# 他のユーザーの crontab を巻き込まないよう、先に /var/spool/cron/crontabs を確かめる。
setup_cron_allow() {
  local spool=/var/spool/cron/crontabs f u others=()
  if [[ -d "${spool}" ]]; then
    for f in "${spool}"/*; do
      [[ -e "${f}" ]] || continue
      u="${f##*/}"
      case "${u}" in
        root|"${ADMIN_USER}") ;;
        "${CLAUDE_USER}")
          warn "${CLAUDE_USER} の crontab が存在する（${f}）。居座りの跡かもしれない。docs/94 の「鍵が漏れたとき」で確認すること（cron.allow に載せないので動かなくなる）" ;;
        *) others+=("${u}") ;;
      esac
    done
  fi
  if ((${#others[@]} > 0)); then
    # 載せずに置くと、そのユーザーの crontab が黙って止まる。人間が判断する。
    warn "${others[*]} の crontab がある。/etc/cron.allow は作らなかった（作ると止まる）。載せるなら ADMIN_USER 以外を足してから再実行すること"
    return 0
  fi
  install -m 644 -D /dev/stdin /etc/cron.allow <<EOF
root
${ADMIN_USER}
EOF
  echo "/etc/cron.allow を置いた（root と ${ADMIN_USER} のみ）"
}

# claude の linger（ログアウト後もユーザーのサービスを残す設定）を polkit で禁じる
# （ADR 0060 決定2）。既定では set-self-linger は誰でも許可で、enable-linger すると
# user@<UID>.service が残る。書き方は stacks/admin-console/webhook/polkit/49-admin-console.rules
# に合わせる。49 は admin-console 用で別のスクリプトが置くので、ここは48の別ファイル。
# polkit は rules.d を監視しているので、再起動は要らない。
setup_claude_polkit_rule() {
  install -m 644 -D /dev/stdin /etc/polkit-1/rules.d/48-claude-no-linger.rules <<EOF
// ${CLAUDE_USER} が loginctl enable-linger で居座れないようにする（docs/adr/0060 決定2）。
// bootstrap/setup.sh が配置する。
polkit.addRule(function(action, subject) {
    if (subject.user != "${CLAUDE_USER}") {
        return polkit.Result.NOT_HANDLED;
    }
    if (action.id == "org.freedesktop.login1.set-self-linger" ||
        action.id == "org.freedesktop.login1.set-user-linger") {
        return polkit.Result.NO;
    }
    return polkit.Result.NOT_HANDLED;
});
EOF
}

# claude のログアウト時にそのセッションのプロセスを殺す（ADR 0060 決定2）。
# 既定の KillUserProcesses=no だと、nohup したプロセスがログアウト後も残る。
# KillOnlyUsers で claude だけに限る（ino の tmux などを巻き込まない）。
# logind は設定を起動時にしか読まないので、内容が変わったときだけ再起動する。
setup_claude_logind_dropin() {
  local conf=/etc/systemd/logind.conf.d/99-m-ino-jp-claude.conf new
  new="$(printf '[Login]\nKillUserProcesses=yes\nKillOnlyUsers=%s\n' "${CLAUDE_USER}")"
  if [[ -f "${conf}" && "$(cat "${conf}")" == "${new}" ]]; then
    echo "logind の drop-in は変更なし（再起動しない）"
    return 0
  fi
  install -m 644 -D /dev/stdin "${conf}" <<<"${new}"
  # 稼働中のVPSで再起動するときは、ino のセッションを残したまま行い、新しい ino の
  # ログインができることを確かめる（docs/94）。再起動しても既存のセッションは切れない。
  systemctl restart systemd-logind
  echo "systemd-logind を再起動した（新しい drop-in を読ませるため）"
}

# apport を止めて mask する（ADR 0060 決定5）。クラッシュしたプロセスのコアダンプを
# 他ユーザーが置いたハンドラ経由で処理させない。/etc/default/apport は編集しない
# （パッケージの更新で衝突するため。mask は unit 側で完結する）。
disable_apport() {
  systemctl disable --now apport.service >/dev/null 2>&1 || true
  systemctl mask apport.service
  # 止めても core_pattern が apport のまま残ることがある。再起動までそのままに
  # しない（ブート後の既定値は mask 済みなので core）。
  if grep -q apport /proc/sys/kernel/core_pattern 2>/dev/null; then
    sysctl -w kernel.core_pattern=core >/dev/null
  fi
  echo "apport.service: $(systemctl is-enabled apport.service 2>&1 || true) / core_pattern: $(cat /proc/sys/kernel/core_pattern)"
}

# ---------------------------------------------------------------------------
# Claude Code 用の読み取り専用ユーザー（docs/adr/0057-claude-readonly-user.md）
# ---------------------------------------------------------------------------
# 関数にしてあるのは、通しの実行（末尾で呼ぶ）と、稼働中VPSへ足すだけの実行
# （ONLY_CLAUDE_USER=1）で同じコードを通すため。再構築用のコードを今回の適用で
# 実機検証できる。
#
# 「何ができないか」は権限の不在で担保する。許可リストは持たない。
#   - sudo グループにも docker グループにも入れない（docker は実質root）
#   - /srv/m-ino-jp・/srv/data・/etc/m-ino-jp は書けない（所有者が ino / root）
#   - 暴走でホストを巻き込まないよう、user-<UID>.slice にメモリ・タスクの上限を掛ける
# 「状況確認」の幅は、adm / systemd-journal グループ（ログの閲覧）と、root が
# 毎分書き出す docker の状態スナップショット（/run/m-ino-jp/snapshot/）で与える。
setup_claude_user() {
  local uid home snap_dir="/run/m-ino-jp/snapshot"

  # 副作用（グループの付け外し・authorized_keys の上書き）の前に、対象が妥当か確かめる。
  guard_claude_user

  # 鍵の検証は副作用の前にやる。壊れた値でユーザーだけ作ると半端な状態が残る。
  if [[ -n "${CLAUDE_SSH_PUBLIC_KEY}" ]]; then
    if [[ "${CLAUDE_SSH_PUBLIC_KEY}" == *$'\n'* ]] \
       || ! ssh-keygen -l -f /dev/stdin <<<"${CLAUDE_SSH_PUBLIC_KEY}" >/dev/null 2>&1; then
      echo "CLAUDE_SSH_PUBLIC_KEY が公開鍵1行として読めない" >&2
      exit 1
    fi
  fi

  log "claude 1. ユーザー ${CLAUDE_USER}"
  if ! id -u "${CLAUDE_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${CLAUDE_USER}"
  fi
  # 他のグループから外す処理は、誰かが手で足した場合の回復用（冪等性のため）。
  # 既に外れていれば deluser は失敗するので無視する。
  for g in sudo docker lxd; do
    deluser "${CLAUDE_USER}" "${g}" >/dev/null 2>&1 || true
  done
  # adm: /var/log の閲覧。systemd-journal: journalctl の全ユニット閲覧。
  usermod -aG adm,systemd-journal "${CLAUDE_USER}"

  uid="$(id -u "${CLAUDE_USER}")"
  home="$(getent passwd "${CLAUDE_USER}" | cut -d: -f6)"

  log "claude 2. ホームの所有者とSSH公開鍵"
  # 所有者の是正は鍵の有無によらず毎回行う（ADR 0060 決定3）。~/.gitconfig もここで
  # root が書く。
  lock_claude_home "${home}"

  if [[ -n "${CLAUDE_SSH_PUBLIC_KEY}" ]]; then
    # root 所有のディレクトリ・ファイルにする。claude 自身が authorized_keys を書き換えて
    # restrict を外したり鍵を足したりできないようにするため。sshd の StrictModes は
    # 「所有者が本人か root で、他人に書けない」ことを要求するので、これで通る。
    install -d -m 755 -o root -g root "${home}/.ssh"
    # restrict は pty・各種転送・~/.ssh/rc を一括で禁じる。pty だけ戻すのは、
    # 人間が入って調べるときに対話シェルが使えないと不便なため。
    install -m 644 -o root -g root /dev/stdin \
      "${home}/.ssh/authorized_keys" <<EOF
restrict,pty ${CLAUDE_SSH_PUBLIC_KEY}
EOF
    echo "公開鍵を ${home}/.ssh/authorized_keys に配置した（root 所有）"
  else
    warn "CLAUDE_SSH_PUBLIC_KEY が空。${CLAUDE_USER} は作ったが、SSHでは入れない"
  fi

  log "claude 3. sshd の AllowUsers"
  # 01-hardening.conf が無いのは、鍵が無くてハードニングを見送ったとき。その状態で
  # AllowUsers を足すと、claude 以外（ino）を締め出す側に倒れるので足さない。
  # AllowUsers は複数行・複数ファイルで累積する（先勝ちではない）ため、01 を
  # 書き換えずに別ファイルで足せる。効いたかは最後に実効値で確認する。
  if [[ -f /etc/ssh/sshd_config.d/01-hardening.conf ]]; then
    local claude_conf=/etc/ssh/sshd_config.d/02-claude-user.conf
    install -m 644 -D /dev/stdin "${claude_conf}" <<EOF
AllowUsers ${CLAUDE_USER}
EOF
    install -d -m 0755 -o root -g root /run/sshd
    if ! sshd -t; then
      rm -f "${claude_conf}"
      echo "sshd の設定が不正だったため、${claude_conf} を取り消した" >&2
      exit 1
    fi
    reload_sshd
    echo "--- sshd の実効 AllowUsers ---"
    sshd -T | grep -i '^allowusers' || true
    echo "------------------------------"
    sshd -T | grep -i '^allowusers' | grep -qw "${CLAUDE_USER}" \
      || warn "sshd の実効設定に ${CLAUDE_USER} が入っていない。AllowUsers が累積しない版かもしれない。01-hardening.conf を直接直すこと"
  else
    warn "01-hardening.conf が無いので AllowUsers は触っていない"
  fi

  log "claude 4. 資源とネットワークの上限"
  # 2GBのホストで、ログインユーザーの暴走（grep -r、fork爆弾など）が常駐サービスを
  # OOMや swap 嵐に巻き込むのを防ぐ。swap を禁じるのは、8GBのswapファイルを
  # このユーザーに食い潰させないため。UID は adduser 任せで再構築のたびに変わりうる
  # ので、ここで引いた実値からファイル名を作る。
  #
  # IPAddressDeny=any: claude は IP 通信を一切しない前提（journalctl・systemctl は
  # D-Bus、git は手元で完結する。名前を引くなら resolvectl query）。ホストは docker の
  # ブリッジ（172.20.0.1 など）にアドレスを持つので、塞がないと claude が Caddy を
  # 迂回して、認証を Caddy の forward_auth に任せている MCP コンテナ（nextcloud-mcp
  # など）へ直接つなげる（ADR 0060 決定1）。SSH の接続は sshd 側で作られたソケットなので
  # 巻き込まれない。
  install -m 644 -D /dev/stdin "/etc/systemd/system/user-${uid}.slice.d/99-m-ino-jp.conf" <<'EOF'
[Slice]
MemoryMax=256M
MemorySwapMax=0
TasksMax=200
CPUQuota=100%
IPAddressDeny=any
EOF
  systemctl daemon-reload

  log "claude 5. docker 状態スナップショット"
  if command -v docker >/dev/null 2>&1; then
    # claude に docker.sock を渡さない代わりに、root が読み取り結果だけを書き出す。
    # docker inspect は環境変数（=秘密）を含むので出さない。
    install -m 755 -D /dev/stdin /usr/local/bin/vps-snapshot <<'EOF'
#!/usr/bin/env bash
# 使い方: vps-snapshot   （systemd の vps-snapshot.timer から毎分、root で呼ばれる）
# docker の状態を /run/m-ino-jp/snapshot/*.txt に書く。読むのは claude ユーザー。
set -euo pipefail
dir=/run/m-ino-jp/snapshot
install -d -m 755 "${dir}"
out() {  # out <ファイル名> <コマンド...>: 一時ファイル経由で置き換え、読み手が途中を見ないようにする
  local f="${dir}/$1"; shift
  { date '+# %F %T %Z'; "$@"; } > "${f}.tmp" 2>&1 || true
  chmod 644 "${f}.tmp"; mv "${f}.tmp" "${f}"
}
cgroup_mem() {  # コンテナごとの RSS / swap / 上限（.claude/rules/compose.md の手順と同じ値）
  local name id d
  while read -r name id; do
    d="/sys/fs/cgroup/system.slice/docker-${id}.scope"
    [[ -d "${d}" ]] || continue
    printf '%s\n' "${name#/}"
    for k in memory.current memory.swap.current memory.max memory.swap.max memory.peak; do
      printf '  %s=%s\n' "${k}" "$(cat "${d}/${k}")"
    done
    sed 's/^/  /' "${d}/memory.events"
  done < <(docker inspect -f '{{.Name}} {{.Id}}' $(docker ps -q))
}
out containers.txt docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}'
out stats.txt docker stats --no-stream
out memory-cgroup.txt cgroup_mem
out disk.txt docker system df
EOF

    install -m 644 -D /dev/stdin /etc/systemd/system/vps-snapshot.service <<'EOF'
[Unit]
Description=Write a read-only snapshot of docker state for the claude user
After=docker.service

[Service]
Type=oneshot
NoNewPrivileges=true
ExecStart=/usr/local/bin/vps-snapshot
Nice=15
IOSchedulingClass=idle
MemoryMax=64M
TimeoutStartSec=1m
# OnFailure=notify@%n.service は付けない。毎分走るので、docker の一時的な不調が
# そのまま通知のフラッドになる（ADR 0043）。止まれば各ファイル先頭の日時が古く
# なるので、読み手（claude）がそれで気付く。
EOF
    install -m 644 -D /dev/stdin /etc/systemd/system/vps-snapshot.timer <<'EOF'
[Unit]
Description=Refresh the docker state snapshot every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now vps-snapshot.timer
    systemctl start vps-snapshot.service
    ls -l "${snap_dir}"
  else
    warn "docker が未導入のためスナップショットを入れていない。docker 導入後に ONLY_CLAUDE_USER=1 で再実行すること"
  fi

  log "claude 6. 居座りの封じ込め（cron・linger・logind・apport）"
  setup_cron_allow
  setup_claude_polkit_rule
  setup_claude_logind_dropin
  disable_apport
  write_needrestart_conf

  log "claude 7. 権限の確認"
  # 構成が崩れていたら、ここで落とす。「読み取り専用」が嘘のまま残るのが一番まずい。
  if id -nG "${CLAUDE_USER}" | tr ' ' '\n' | grep -Eqx 'sudo|docker|lxd|root'; then
    echo "${CLAUDE_USER} が特権グループに入っている: $(id -nG "${CLAUDE_USER}")" >&2
    exit 1
  fi
  echo "所属グループ: $(id -nG "${CLAUDE_USER}")"

  # 読めてはいけないものが読めていないか。見つけても自動では chmod しない
  # （どう塞ぐかはサービスごとの判断で、勝手に変えるとコンテナが読めなくなる）。
  # 警告として残し、人間が対処する。
  local exposed=()
  while IFS= read -r f; do
    exposed+=("${f}")
  done < <(runuser -u "${CLAUDE_USER}" -- bash -c '
    shopt -s nullglob
    for f in /etc/m-ino-jp/*.env /srv/m-ino-jp/stacks/*/.env /srv/m-ino-jp/stacks/*/*.env \
             /srv/data/zitadel/pat/* /srv/data/*/.env; do
      [[ -f "$f" && -r "$f" ]] && echo "$f"
    done; true')
  if ((${#exposed[@]} > 0)); then
    warn "claude から秘密情報らしきファイルが読める: ${exposed[*]}"
  else
    echo "既知の秘密情報の置き場所は claude から読めない"
  fi

  # 永続データ（DB・アップロードファイル）も「状況確認」の範囲ではない。
  # 件数と先頭だけ出す。0件でなければ、中身を見て塞ぐか許容するかを人間が決める。
  local data_readable
  data_readable="$(runuser -u "${CLAUDE_USER}" -- find /srv/data -xdev -type f -readable 2>/dev/null | head -n 20 || true)"
  if [[ -n "${data_readable}" ]]; then
    warn "claude から /srv/data 配下のファイルが読める（先頭20件）: $(tr '\n' ' ' <<<"${data_readable}")"
  else
    echo "/srv/data 配下に claude から読めるファイルは無い"
  fi
}

# ---------------------------------------------------------------------------
# 通知の送信スクリプト（notify-discord / notify-email）
# ---------------------------------------------------------------------------
# 関数にしてあるのは、通しの実行（11節で呼ぶ）と、稼働中VPSへ入れ直すだけの実行
# （ONLY_NOTIFY=1）で同じコードを通すため。通しで流すと ufw --force reset などを
# 含むので、稼働中のVPSでは流せない。
#
# Webhook URL・APIキーは curl の引数に載せない。引数は /proc/<pid>/cmdline から
# 他のユーザー（claude）にも見える（docs/adr/0059）。printf は bash の組み込みなので
# 引数にならず、プロセス置換で curl へ渡る（.claude/rules/shell.md「秘密情報」）。
setup_notify_senders() {
  # Discord Webhook への通知。メールサーバを立てない代わりの仕組み。
  install -m 755 -D /dev/stdin /usr/local/bin/notify-discord <<'EOF'
#!/usr/bin/env bash
# 使い方: notify-discord [--level=high|low] "メッセージ"
#   systemd からは notify.d/10-discord 経由（OnFailure=notify@%n.service）で呼ばれる
#   levelを省略した場合はhigh扱い（既存の呼び出し元との後方互換のため）。
#   high: DISCORD_MENTION_ID が設定されていればメンション付きで送る
#   low : メンション無しで送る（気付いたら見る程度の通知向け）
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

level=high
if [[ "${1:-}" == --level=* ]]; then
  level="${1#--level=}"
  shift
fi

mention=""
if [[ "${level}" == "high" && -n "${DISCORD_MENTION_ID:-}" ]]; then
  mention="<@${DISCORD_MENTION_ID}> "
fi

message="${1:-(メッセージなし)}"
payload=$(jq -Rn --arg c "[$(hostname)] ${mention}${message}" '{content: $c}')
# Webhook URLは秘密（知っていれば誰でも投稿できる）。引数に載せず -K で渡す。
# Webhook URLに " と \ は含まれないので、設定ファイルの引用符で囲んでよい。
curl -fsS -H 'Content-Type: application/json' -d "${payload}" \
  -K <(printf 'url = "%s"\n' "${DISCORD_WEBHOOK_URL}") >/dev/null
EOF

  # Brevo Transactional Email API への通知。notify-discordと対称的な構成
  # （docs/adr/0030-notify-email-brevo.md）。
  install -m 755 -D /dev/stdin /usr/local/bin/notify-email <<'EOF'
#!/usr/bin/env bash
# 使い方: notify-email [--level=high|low] "メッセージ"
#   levelを省略した場合はhigh扱い（既存の呼び出し元との後方互換のため）。
#   low（気付いたら見る程度の通知）はメール配信そのものをしない（docs/adr/0035）。
set -euo pipefail

level=high
if [[ "${1:-}" == --level=* ]]; then
  level="${1#--level=}"
  shift
fi

if [[ "${level}" == "low" ]]; then
  exit 0
fi

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

# APIキーは引数に載せず、ヘッダをプロセス置換のファイルとして渡す。
curl -fsS -X POST "https://api.brevo.com/v3/smtp/email" \
  -H @<(printf 'api-key: %s' "${BREVO_API_KEY}") \
  -H "Content-Type: application/json" \
  -d "${payload}" >/dev/null
EOF
}

if [[ "${ONLY_CLAUDE_USER}" == "1" ]]; then
  setup_claude_user
  log "完了（ONLY_CLAUDE_USER=1: claude ユーザーの節のみ）"
  print_warnings
  exit 0
fi

if [[ "${ONLY_NOTIFY}" == "1" ]]; then
  setup_notify_senders
  log "完了（ONLY_NOTIFY=1: notify-discord / notify-email のみ）"
  exit 0
fi

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

  # 初回の通し実行では ssh.service はまだ起動していないので reload は走らない。
  # 稼働中のVPSでこの節を流し直したときは reload が効く（reload_sshd の説明を参照）。
  reload_sshd

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
# （drop-in の中身は write_needrestart_conf。ONLY_CLAUDE_USER=1 でも同じものを通す）
write_needrestart_conf

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
# subnetを固定する理由: stacks/proxy/compose.yamlのCaddyが、ホスト上の
# webhook（stacks/admin-console）へこのネットワークのゲートウェイIP経由で
# 到達する（ADR 0016）。サブネットをDocker任せにすると、このネットワークを
# 作り直したときにゲートウェイIPが変わり、Caddyfile側の設定と食い違う。
docker network inspect edge >/dev/null 2>&1 || docker network create --subnet=172.20.0.0/24 edge

# ---------------------------------------------------------------------------
log "11. ディレクトリと通知スクリプト"
# ---------------------------------------------------------------------------
install -d -m 755 -o "${ADMIN_USER}" -g "${admin_group}" /srv/m-ino-jp
# /srv/data は 750。読み取り専用ユーザー claude（${admin_group} グループの外）から
# 永続データ（DB・Nextcloud のファイル・CouchDB の Vault）を見せないため。親を閉じれば
# 配下を1つずつ chmod せずに済み、コンテナ内ユーザーの権限にも触らない（bind mount は
# dockerd=root が親パスをたどるので、コンテナには影響しない。docs/94、ADR 0057）。
# /srv/m-ino-jp は 755 のまま（リポジトリは claude にも読ませる）。.env は 600。
install -d -m 750 -o "${ADMIN_USER}" -g "${admin_group}" /srv/data

# 書き込みはrootだけ、読み取りは管理ユーザーにも許す。
# notify-discord を ino がそのまま実行できるようにするため。
install -d -m 750 -o root -g "${admin_group}" /etc/m-ino-jp

log "notify-discord / notify-email を配置"
setup_notify_senders

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
# 使い方: notify [--level=high|low] "メッセージ"
#   level未指定はhigh（強い通知＝Discordメンション付き＋メール配信あり）。
#   low（弱い通知＝Discordメンション無し＋メール配信無し。気付いたら見る程度）
#   levelは各チャンネル(notify.d/*)にそのまま引き渡すだけで、ここでは解釈しない
#   （docs/adr/0035）。
#
# 【フラッド抑制】DiscordのWebhookにもBrevoの送信数にも上限があり、短時間に
# 大量送信するとレート制限に当たるだけでなく、送信ドメインがスパム扱いされる
# 恐れがある。通知経路はすべてこのスクリプトを通るので、ここで2段階に絞る
# （docs/adr/0043）。
#   1. 同一内容の再送抑制: 同じ level+本文 は DEDUP_WINDOW 秒に1回だけ送る
#   2. 全体の上限:         RATE_WINDOW 秒あたり RATE_MAX 件で打ち止め
# どちらも抑制した件数を数えていて、次に実際に送るときの本文へ追記するので、
# 「何件起きたか」が失われることはない（届くのが遅れるだけ）。
set -euo pipefail

# 既定値。必要なら呼び出し側が環境変数で上書きできる。
NOTIFY_DEDUP_WINDOW="${NOTIFY_DEDUP_WINDOW:-1800}"   # 30分
NOTIFY_RATE_WINDOW="${NOTIFY_RATE_WINDOW:-3600}"     # 1時間
NOTIFY_RATE_MAX="${NOTIFY_RATE_MAX:-20}"             # 1時間あたり20件
STATE_DIR=/run/m-ino-jp/notify

level=high
if [[ "${1:-}" == --level=* ]]; then
  level="${1#--level=}"
  shift
fi
msg="${1:?メッセージを指定してください}"

now="$(date +%s)"
extra=""

# 状態ディレクトリが使えない環境（tmpfiles未適用など）では抑制せず素通しする。
# 「通知が多すぎる」より「必要な通知が届かない」方が危険なので、抑制の仕組みが
# 壊れているときは抑制しない側へ倒す。
if [[ -d "${STATE_DIR}" && -w "${STATE_DIR}" ]]; then
  key="$(printf '%s\n%s' "${level}" "${msg}" | sha256sum | cut -c1-32)"
  dedup_file="${STATE_DIR}/msg-${key}"
  rate_file="${STATE_DIR}/rate"

  # --- 1. 同一内容の再送抑制 ---
  last=0
  dropped=0
  if [[ -f "${dedup_file}" ]]; then
    read -r last dropped < "${dedup_file}" || true
  fi
  if (( now - ${last:-0} < NOTIFY_DEDUP_WINDOW )); then
    dropped=$(( ${dropped:-0} + 1 ))
    printf '%s %s\n' "${last}" "${dropped}" > "${dedup_file}"
    echo "notify: 同一内容を${NOTIFY_DEDUP_WINDOW}秒以内に送信済みのため抑制した（この窓で${dropped}件目）" >&2
    exit 0
  fi
  if (( ${dropped:-0} > 0 )); then
    extra="${extra}"$'\n'"（直前の${NOTIFY_DEDUP_WINDOW}秒間に同じ通知を${dropped}件抑制しました）"
  fi

  # --- 2. 全体の上限 ---
  win_start=0
  sent=0
  if [[ -f "${rate_file}" ]]; then
    read -r win_start sent < "${rate_file}" || true
  fi
  if (( now - ${win_start:-0} >= NOTIFY_RATE_WINDOW )); then
    # 窓が明けた。前の窓で打ち止めていた分があれば知らせる。
    if (( ${sent:-0} > NOTIFY_RATE_MAX )); then
      extra="${extra}"$'\n'"（前の${NOTIFY_RATE_WINDOW}秒間は上限超過で$(( sent - NOTIFY_RATE_MAX ))件の通知を止めていました）"
    fi
    win_start="${now}"
    sent=0
  fi
  sent=$(( ${sent:-0} + 1 ))
  printf '%s %s\n' "${win_start}" "${sent}" > "${rate_file}"

  if (( sent > NOTIFY_RATE_MAX )); then
    echo "notify: ${NOTIFY_RATE_WINDOW}秒あたり${NOTIFY_RATE_MAX}件の上限を超えたため抑制した" >&2
    exit 0
  fi
  if (( sent == NOTIFY_RATE_MAX )); then
    extra="${extra}"$'\n'"（これが${NOTIFY_RATE_WINDOW}秒あたりの上限${NOTIFY_RATE_MAX}件目です。以降この窓が明けるまで通知を止めます）"
  fi

  # 実際に送るので、同一内容の抑制タイマーを now から測り直す。
  printf '%s 0\n' "${now}" > "${dedup_file}"

  # 古いdedupファイルの掃除（/runはtmpfsだが、再起動間隔が長いと溜まる）。
  find "${STATE_DIR}" -maxdepth 1 -name 'msg-*' -type f \
    -mmin "+$(( (NOTIFY_DEDUP_WINDOW / 60) + 60 ))" -delete 2>/dev/null || true
fi

shopt -s nullglob
channels=(/etc/m-ino-jp/notify.d/*)

if [[ ${#channels[@]} -eq 0 ]]; then
  echo "notify: /etc/m-ino-jp/notify.d/ にチャンネルが無い" >&2
  exit 1
fi

status=0
for channel in "${channels[@]}"; do
  [[ -x "${channel}" ]] || continue
  "${channel}" --level="${level}" "${msg}${extra}" || { echo "notify: ${channel} が失敗しました" >&2; status=1; }
done
exit "${status}"
EOF

# notifyのフラッド抑制が使う状態ディレクトリ（docs/adr/0043）。
# /run はtmpfsでブートのたびに消えるので、systemd-tmpfilesに作らせる。
# notifyの呼び出し元はroot（notify@.service）と ino（vuln-scan等、User=ino）の
# 両方があるため、グループ書き込みを許可する。setgid（2770）にして、どちらが
# 作ったファイルでも他方から消せるようにしておく。
install -m 644 -D /dev/stdin /etc/tmpfiles.d/m-ino-jp-notify.conf <<EOF
d /run/m-ino-jp 0755 root root -
d /run/m-ino-jp/notify 2770 root ${admin_group} -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/m-ino-jp-notify.conf

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
# 強い通知（notify --level=high、既定）でメンションするDiscordのユーザーID。
# 未設定でも動く（メンション無しで送るだけ）。docs/adr/0035。
DISCORD_MENTION_ID=
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
log "12. Claude Code 用の読み取り専用ユーザー"
# ---------------------------------------------------------------------------
# sshd のハードニング(5)と docker(10)の後で呼ぶ。AllowUsers を足す相手の
# 01-hardening.conf と、スナップショットが叩く docker が揃っている必要がある。
setup_claude_user

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

print_warnings
