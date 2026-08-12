#!/usr/bin/env bash
#
# さくらのVPS スタートアップスクリプト（マイスクリプト）に貼り付けるもの。
#
# 使い方:
#   1. 下の SSH_PUBLIC_KEY を自分の公開鍵に書き換える
#   2. さくらのコントロールパネル > スタートアップスクリプト > マイスクリプトに
#      このファイルの内容を貼り付けて保存
#   3. OS再インストール時にこのスクリプトを選択する
#
# 注意:
#   - スタートアップスクリプトは「標準OSインストール」でのみ利用できる
#   - コントロールパネルに入力した値はVPS内部のログに残るため、
#     ここに秘密情報を書かないこと（公開鍵は公開情報なので問題ない）
#   - 本体は GitHub から取得する。このスクリプト自体は短く保つ
#   - 本体（bootstrap/setup.sh）を取得する REPO_RAW_BASE は、非公開の
#     m-ino-jp 本体リポジトリではなく、公開用の m-ino-jp-bootstrap
#     リポジトリを指す。raw.githubusercontent.com は非公開リポジトリの
#     ファイルを認証なしには配信できないため。詳細は bootstrap/README.md

set -euo pipefail

# --- ここを書き換える ------------------------------------------------------
SSH_PUBLIC_KEY='ssh-ed25519 AAAA...ここに公開鍵を貼る... ino@local'
ADMIN_USER='ino'
HOSTNAME_FQDN='m-ino.jp'
# 公開用リポジトリ（m-ino-jp-bootstrap）を指す。本体（m-ino-jp）ではない。
REPO_RAW_BASE='https://raw.githubusercontent.com/YOUR_GITHUB_USER/m-ino-jp-bootstrap/main'
# ---------------------------------------------------------------------------

export SSH_PUBLIC_KEY ADMIN_USER HOSTNAME_FQDN

apt-get update
apt-get install -y curl ca-certificates

curl -fsSL "${REPO_RAW_BASE}/bootstrap/setup.sh" -o /root/setup.sh
chmod +x /root/setup.sh
/root/setup.sh 2>&1 | tee /root/setup.log
