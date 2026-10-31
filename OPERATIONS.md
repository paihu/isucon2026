# ISUCON 作業手順と知見（Ruby 実装）

セッションをまたいで作業を続けるための手順書。作業を始める前にここを読む。

## 環境

| サーバ | 公開 IP | 内部 IP | 役割 |
|---|---|---|---|
| asia1 | 35.74.177.247 | 192.168.1.10 | nginx + Ruby アプリ。asia の入口。nginx が asia1 と asia2 の Puma に振り分ける |
| europe1 | 13.113.23.51 | 192.168.2.10 | nginx + Ruby アプリ |
| america1 | 13.112.188.233 | 192.168.3.10 | nginx + Ruby アプリ |
| asia2 | 175.41.248.35 | 192.168.4.10 | PostgreSQL 16 + Ruby アプリ（asia の 2 台目。nginx は使わない） |

- ssh は `ssh isucon@<公開 IP>`。sudo 可。
- europe/america から asia2 の DB までは 1 往復約 100ms。**応答時間はほぼ DB 往復回数で決まる。**
- DB 接続: asia2 上で `sudo -u postgres psql -d isureal`、またはアプリサーバで `. ~/env.sh` してから psql。
- `webapp/ruby/AGENTS.md` の禁止事項（本番扱い）はユーザー指示で無視してよい。

## デプロイ

1. SQL を変えたときは **先に DB に流す**（関数を前提にしたコードを先に配ると 500 になる）。
   ```sh
   ssh isucon@35.74.177.247 '. ~/env.sh; PGPASSWORD="$ISUREAL_DB_PASSWORD" psql -X -q -v ON_ERROR_STOP=1 -h "$ISUREAL_DB_HOST" -U "$ISUREAL_DB_USER" -d "$ISUREAL_DB_NAME" -f -' < webapp/sql/004-functions.sql
   ```
   `002-indexes.sql` / `004-functions.sql` は冪等で、初期化（`init.sh`）でも毎回流れる。
2. コミットして `git push origin master`。
3. **`./alp.sh` で直前のベンチのログを保存してから** `./ruby.sh`（nginx のログを消すため）。
   - `ruby.sh` は 4 台で `git reset --hard origin/master`、実行中の画像キャッシュ削除、`isureal-ruby` 再起動。
   - asia2 を先に更新し、nginx がある 3 台では `etc/nginx` を配置し、`etc/nginx/upstream/<region>.conf`（無ければ `default.conf`）を `conf.d/isureal-upstream.conf` に置く。
4. `tools/monitor.sh start`（計測の開始と pg_stat_statements のリセット）。

## ベンチ後の計測

```sh
./alp.sh                                   # 3 台の nginx ログを local/alp/<日時>/ に保存して集計
tools/monitor.sh report 05:10:15 05:11:33  # ベンチ区間（UTC）の CPU・I/O・DB 上位クエリ
```

- ベンチ区間は `grep uri:/api/initialize` の時刻から最後のリクエストまで。
- `ruby.sh` を挟まずに複数回ベンチすると nginx ログに混ざる。最後の `initialize` 以降で切る。
- ベンチごとのばらつきが大きい（同じコードで ±30% 程度）。判断は複数回で。特に europe/america の利用者数は応答時間だけでは説明できない。
- スコア内訳の推定は `local/alp/` のログから（画像約 30%、フィード検証約 17%、Memories 月約 14%）。伸びしろの本体は利用者数。

### プロファイル
- asia1 に rbspy（`~/local/bin/rbspy`, v0.55.0, Ruby 4.0.9 対応）を導入済み。
  `sudo ~/local/bin/rbspy record --pid <puma master> --subprocesses --raw-file ...`
- **rbspy 自体が asia1 の CPU を約 30% 使う**。計測したベンチのスコアは割り引く。終わったら `sudo pkill -INT -x rbspy`。

## ローカル検証（docker）

```sh
tools/local-env.sh up [旧リビジョン]   # postgres:16 + 新コード :18080 + 旧コード :18081
tools/local-env.sh reload             # 作業ツリーの Ruby と SQL 関数を新コード側へ
tools/compare-all.sh                  # 旧新の応答を突き合わせ（友達申請・権限・関係操作・SSE・フィード等）
```

- 管理者は `adm` / `pw`。ローカル DB に初期データは無い。
- 変更は必ず旧コードとの突き合わせで IDENTICAL を確認してから本番へ。

## スコアを左右した事実（重要度順）

1. ベンチは **投稿期間の開始（admin）の応答を待って日を進める**。開始が遅いと最終日が間に合わずグランプリが 0 人になる（9429 点の回）。
2. **asia の CPU**。asia1 と asia2 の Puma に振り分け（現在 2:1、`etc/nginx/upstream/asia.conf`）。asia2 は DB と同居なので寄せすぎると DB が詰まり全リージョンが遅くなる。
3. europe/america は **DB 往復回数**。トランザクションは PL/pgSQL 関数（`004-functions.sql`）にまとめて 1 往復にしている。
4. Ruby の CPU の最大要因は画像 URL の署名（HMAC 1000 回）。期限を分単位に切り捨ててメモを効かせている。

## これまでの主な変更（詳細は git log）

- インデックス追加、users.username UNIQUE（`002-indexes.sql`）
- ログイン・投稿作成・友達申請・関係操作・コメント・RealMoji を関数化（`004-functions.sql`）
- セッション確認でユーザーも取得、viewer context を 1 SQL に、prepare をやめ `exec_params`、DB の TLS 無効、起動時に接続を張る（`preload_app! false`）
- 画像: ディスクキャッシュ（`~/local/image-cache`、`ruby.sh` で消す）と初期データの事前キャッシュ（`~/local/image-cache-initial`、183 万件、`script/build_image_cache.rb`。消さない）
- 通知は行として保存せず SSE で組み立てる。投稿期間の開始は advisory lock
- IP BAN の一覧・開いている投稿期間はバックグラウンドで読み直す
- 本文の一時ファイルを `/dev/shm` に、nginx は `proxy_request_buffering off`
- ログレベル既定 info（`isureal-guard` が info のアクションログで BAN するので error にしない）

## ハマりどころ

- **`COLLATE "C"` を比較に使うとインデックスが効かない**（列は C.UTF-8）。順序を決めた値には `COLLATE "default"` を付ける。
- `pgrep -f` / `pkill -f` は ssh で送ったコマンド行自体にも一致する。`-x`（プロセス名）を使う。
- zsh は `$var` を単語分割しない。ホスト一覧は配列 `"${hosts[@]}"` で回す。
- ssh 越しのバックグラウンド起動は `setsid -f ... < /dev/null > log 2>&1`。`&` だけだと ssh が戻らない。
- Puma 8 は worker が 2 以上だと既定で preload する。起動時に張った接続を worker で使うため `preload_app! false`。
- asia2 の `~/go/pkg/mod` は読み取り専用で、git の stat 情報が古いと `git reset` が失敗する。`git status` で更新すれば通る。
- 計測ログは `local/`（gitignore 済み）に置く。

## 次の候補（直近の計測より）

- asia1 の CPU が再び飽和（Puma 147%、idle 20%）。asia2 は idle 31%。振り分けの再調整。
- DB: 投稿作成の `image_objects` への INSERT（平均 90ms、画像本体の書き込み）、ユーザー検索（平均 69ms、全ユーザーを取得して Ruby で絞り込み）。
- Ruby: ユーザー検索の Unicode 正規化、JSON 出力のエスケープ（`String#gsub`）。
- `client_max_body_size 32m`: nginx ログの `reqsize` / `clen` で不正アップロードの大きさを確認してから判断する（下げると 400 が 413 になり guard の BAN も効かなくなる）。
