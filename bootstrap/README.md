# bootstrap

さくらのVPSのスタートアップスクリプトから実行される、OS初期設定一式。

## なぜここだけ別リポジトリに複製するのか

さくらのコンソールから実行するブートストラップは `curl -fsSL <URL> | bash` のような認証なしのHTTP取得を行う。`raw.githubusercontent.com` は**非公開リポジトリのファイルを認証なしには配信できない**ため、この `m-ino-jp` 本体を非公開に保ったまま使うには、公開用の別リポジトリが要る。

このディレクトリ（`bootstrap/`）は元々「秘密情報を書かない」制約で設計してある（`.claude/rules/shell.md` 参照）。SSH公開鍵は含まれるが、公開鍵は公開してよい情報なので問題ない。

## 構成

| リポジトリ | 可視性 | 役割 |
|---|---|---|
| `m-ino-jp`（本体・ここ） | 非公開 | 開発・編集の場所。常にこちらを編集する |
| `m-ino-jp-bootstrap` | 公開 | `raw.githubusercontent.com` からの配信専用。**直接編集しない** |

## 同期方法（手動）

`bootstrap/` 配下を変更したら、公開用リポジトリにコピーしてpushする。

```bash
# m-ino-jp のリポジトリルートで実行
rsync -av --delete --exclude=startup-script.sh bootstrap/ ../m-ino-jp-bootstrap/bootstrap/
cd ../m-ino-jp-bootstrap
git add -A
git commit -m "sync from m-ino-jp bootstrap/"
git push
```

**`startup-script.sh` は同期しない。** これはコントロールパネルに貼り付けて使うもので、HTTPで取得する必要がない。公開する必要があるのは `setup.sh` だけなので、公開範囲は最小にしておく。

自動化（GitHub Actions等）は行わない。変更頻度が低く、手動コピーで十分足りるため。

## `setup.sh` が読む環境変数

`startup-script.sh` が `export` して `setup.sh` に渡す。稼働中のVPSで手動実行するときは `sudo` の後ろに並べる。

| 変数 | 役割 |
|---|---|
| `SSH_PUBLIC_KEY` | 管理ユーザー `ino` の `authorized_keys` に入れる鍵（複数行可）。**上書きなので、書いていない鍵は消える** |
| `CLAUDE_SSH_PUBLIC_KEY` | Claude Code 用の読み取り専用ユーザー `claude` の鍵（1行）。`sudo` も `docker` グループも持たず、`restrict,pty` 付きで登録される。空だと `claude` は作られるがSSHでは入れない |
| `ONLY_CLAUDE_USER=1` | `claude` ユーザーの節だけを実行して終了する。**稼働中のVPSに `claude` を後から追加する**ときに付ける（ufw・Docker・`ino` の鍵には触らない）。手順は `docs/94-claude-readonly-user.md`、設計は `docs/adr/0057-claude-readonly-user.md` |

`claude` の節は `sshd` の drop-in（`02-claude-user.conf`）と `/srv/data` の権限（750）を触るため、稼働中に流すときは `CLAUDE.md` の最重要ルール2（別セッションを開いたまま、新規セッションの疎通確認が取れるまで閉じない）に従う。

## 初回セットアップ（公開用リポジトリを作る）

```bash
# GitHub上で m-ino-jp-bootstrap という名前の「公開」リポジトリを作成してから
git clone https://github.com/m-ino13/m-ino-jp-bootstrap.git ../m-ino-jp-bootstrap
rsync -av --exclude=startup-script.sh bootstrap/ ../m-ino-jp-bootstrap/bootstrap/
cd ../m-ino-jp-bootstrap
git add -A
git commit -m "initial import"
git push
```

## 忘れないこと

`bootstrap/setup.sh` を変更したのに公開用リポジトリへの反映を忘れると、**さくらのコンソールから実行されるスクリプトが古いまま**になる。変更のたびに同期する習慣にする。次にOS再インストールする前には、必ず公開用リポジトリの中身が最新か確認すること。

**稼働中のVPSで `ONLY_CLAUDE_USER=1` を流すだけなら、この同期は要らない**（VPS上のチェックアウトの `bootstrap/setup.sh` を直接実行するため）。同期が要るのは、OS再インストール時の `startup-script.sh` が公開用リポジトリから `setup.sh` を取る経路のためだけ。
