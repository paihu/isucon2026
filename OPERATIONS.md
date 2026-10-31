# ISUCON 作業手順と知見（Ruby 実装）

セッションをまたいで作業を続けるための手順書。作業を始める前にここを読む。

## 環境

| サーバ | 公開 IP | 内部 IP | 役割 |
|---|---|---|---|
| asia1 | 35.74.177.247 | 192.168.1.10 | nginx + Ruby アプリ。asia の入口。asia は asia1 だけで受ける（asia2 は backup）、管理者 API は asia1 の専用 Puma（:8082、`etc/systemd/isureal-ruby-admin.service`）（`etc/nginx/upstream/asia.conf`） |
| europe1 | 13.113.23.51 | 192.168.2.10 | nginx + Ruby アプリ |
| america1 | 13.112.188.233 | 192.168.3.10 | nginx + Ruby アプリ |
| asia2 | 175.41.248.35 | 192.168.4.10 | PostgreSQL 16 + Ruby アプリ（asia1 が落ちたときの backup。nginx は使わない） |

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

> **2026-10-31 の最終走行に向けて計測を止めている。** 計測するときは次の 3 つを戻す。
> - nginx のアクセスログ: `etc/nginx/conf.d/alp.conf` の `access_log off;` を `access_log /var/log/nginx/access.log ltsv;` に戻して `ruby.sh`。
> - pg_stat_statements: asia2 で `ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'; ALTER SYSTEM SET pg_stat_statements.track = 'all';` → PostgreSQL を再起動 → `ruby.sh`（アプリの DB 接続を張り直す）。
> - アクションログは isureal-guard が BAN に使うもの（ログイン失敗の 401、abuse 付き）と 5xx だけを info で出す。全リクエストを見るには `ISUREAL_LOG_LEVEL=debug`。

```sh
./alp.sh                                   # 3 台の nginx ログを local/alp/<日時>/ に保存して集計
tools/monitor.sh report 05:10:15 05:11:33  # ベンチ区間（UTC）の CPU・I/O・DB 上位クエリ
```

- ベンチ区間は `grep uri:/api/initialize` の時刻から最後のリクエストまで。ベンチが回ったかどうかもログの最終行の時刻ではなく `initialize` の有無で判断する（動作確認の curl や外部スキャナのアクセスも残る）。
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
2. **asia2 の DB の CPU**。europe/america の利用者が増えると DB が詰まり、DB に近い asia が最も影響を受ける。asia のアプリは asia1 だけで受ける（`etc/nginx/upstream/asia.conf` で asia2 は backup）。asia1 が詰まったら asia2 に一部戻す。
3. europe/america は **DB 往復回数**。トランザクションは PL/pgSQL 関数（`004-functions.sql`）にまとめて 1 往復にしている。
4. Ruby の CPU の最大要因は画像 URL の署名（HMAC 1000 回、rbspy で asia1 の CPU の約 3/4）。C（`webapp/ruby/ext/iterated_hmac.c`、`ruby.sh` が各ホストで gcc ビルド）で 4.2ms → 0.39ms。期限は 2 分単位に切り捨ててメモを効かせている。

## これまでの主な変更（詳細は git log）

- インデックス追加、users.username UNIQUE（`002-indexes.sql`）
- ログイン・投稿作成・友達申請・関係操作・コメント・RealMoji を関数化（`004-functions.sql`）
- セッション確認でユーザーも取得、viewer context を 1 SQL に、prepare をやめ `exec_params`、DB の TLS 無効、起動時に接続を張る（`preload_app! false`）
- 画像: ディスクキャッシュ（`~/local/image-cache`、`ruby.sh` で消す）と初期データの事前キャッシュ（`~/local/image-cache-initial`、183 万件、`script/build_image_cache.rb`。消さない）
- 作成した画像の本体は DB に入れない（`image_objects.data` は空）。作成したサーバーの `~/local/image-cache` に置き、`image_objects.origin` に `192.168.x.10:8080` を記録。他のサーバーはキャッシュに無いとき `GET /internal/images/:id`（8080 直、プライベートアドレスからのみ）で取り寄せる。`ruby.sh` 後は次の初期化まで、それ以前に作成された画像は取れない（ベンチは初期化から始まるので問題ない）
- `GET /api/images` の本体は nginx が返す。アプリは署名・期限・状態を確かめ、ディスクにあれば `X-Accel-Redirect: /_image_files/{initial,runtime}/<id>` だけ返す（`ImageCache.nginx_uri`）。nginx を持たない asia2 は本体を自分で返す（`/etc/nginx/conf.d/isureal-upstream.conf` の有無で判定）。テストで画像 URL を JSON から取るときは `\u0026` のエスケープに注意
- 画像を作る POST（投稿・RealMoji・プロフィール画像）は nginx で各ホストのローカルのアプリに送る。asia2 は DB と 2 コアを取り合うため、asia2 が送信元だと取り寄せが数〜十数秒かかり、待つ側（asia1）のスレッドが詰まって投稿期間の開始まで遅れた（50396/51037 の回）
- 通知は行として保存せず SSE で組み立てる。投稿期間の開始は advisory lock
- IP BAN の一覧・開いている投稿期間はバックグラウンドで読み直す
- 本文の一時ファイルを `/dev/shm` に、nginx は `proxy_request_buffering off`
- ログレベル既定 info（`isureal-guard` が info のアクションログで BAN するので error にしない）
- 2MB 以上の `PUT /api/me/profile-image` の本文は nginx がアプリに渡さない（空の本文として渡し、アプリは不正画像と同じ 400 と abuse ログを返す）。不正アップロードは平均 24MB、正規は最大 26KB
- 投稿・RealMoji・プロフィール画像の作成時に自サーバーの画像キャッシュへ書く
- Puma: europe/america はスレッド 32・DB 接続 31（worker ごと）、asia は 16・15（`config/puma.rb` で `ISUREAL_REGION` から決定）。asia2 の PostgreSQL は `max_connections = 300`（アプリの接続は合計約 186）、`shared_buffers = 512MB`、`wal_buffers = 64MB`、`max_wal_size = 4GB`（wal_buffers 4MB では WAL 書き出しの 96% がバッファ満杯によるものだった）
- asia2 の PostgreSQL は `synchronous_commit = off`（ALTER SYSTEM。OS ごと落ちると直前 1 秒弱のコミットを失いうるが、正常な再起動では失わない）

## 再起動への耐性（2026-10-31 にローカルで確認）

- アプリが DB より先に起動しても、worker の起動失敗を Puma が繰り返し、DB が上がれば約 5 秒で自動復旧する（失敗中は CPU とログを消費する）。
- 再起動直後にベンチを回す場合: europe/america のワーカーの起動は、起動時の DB 接続を並列で張るようにして 24 秒 → 約 2.5 秒になった（それまでは起動直後のベンチが地域チェックでタイムアウトして FAIL した）。念のため再起動後は `journalctl -u isureal-ruby | grep booted` を確認してから回す。
- `/dev/shm` の中身は systemd-logind（RemoveIPC=yes）が isucon の SSH セッションが全部閉じたときに消す。画像状態キャッシュは書き込み時に作り直し、署名キャッシュも書き込み時に作るので影響はない。
- Puma のファイル数上限は drop-in で 65536（既定のソフト上限 1024 では asia が 400 人を超えて Too many open files になった）。
- アプリ稼働中に DB だけ再起動すると、直後の数秒は 500 になるが、IP BAN・投稿期間を読み直すバックグラウンドスレッドが切れた接続を捨てるので約 2 秒で回復する。
- PostgreSQL を再起動したら `ruby.sh` でアプリも再起動する（起動時に張る接続が切れ、張り直しは使われた分だけになるため）。
- 自動起動: 3 台は isureal-ruby / nginx / isureal-guard が enabled、asia2 は isureal-ruby / isureal-guard / postgresql が enabled（nginx は使わない）。
- 再起動で消えるもの: /dev/shm の一時ファイル、vmstat/pidstat の記録（`tools/monitor.sh start` で再開）。画像キャッシュ（`~/local/image-cache*`）は残る。

## ハマりどころ

- **systemd-logind の `RemoveIPC`（Ubuntu の既定は yes）は、isucon の ssh が全部切れると isucon が `/dev/shm` に作ったファイルを消す。** アプリは isucon で動くので、`/dev/shm/isureal-image-state` 等が消えて画像取得が 500 になり、再起動後のベンチが FAIL した（再起動前は誰かの ssh が残っていて起きなかった）。4 台に `/etc/systemd/logind.conf.d/isureal.conf`（`RemoveIPC=no`）を置いて `systemd-logind` を再起動済み。再構築したら置き直す。
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
