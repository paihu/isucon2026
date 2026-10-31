#!/bin/bash
# ローカル検証環境（docker）。新コード :18080（作業ツリー）、旧コード :18081（指定リビジョン）、DB は postgres:16。
# usage:
#   tools/local-env.sh up [OLD_REV]   # 環境を作り直す（OLD_REV 既定: HEAD）
#   tools/local-env.sh reload         # 作業ツリーの Ruby コードと SQL 関数を新コード側へ反映
#   tools/local-env.sh old OLD_REV    # 旧コード側だけ指定リビジョンで作り直す
set -eu
cd "$(dirname "$0")/.."
root=$PWD

psql_file() { docker exec -i isutest-pg psql -q -U isureal -d isureal -v ON_ERROR_STOP=1 < "$1"; }

run_app() { # name port srcdir
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" --network isutest -p "$2":8080 -v "$3":/src:ro -v isutest-bundle:/bundle \
    -e ISUREAL_DB_HOST=isutest-pg -e ISUREAL_REGION=asia -e BUNDLE_PATH=/bundle -e BUNDLE_WITHOUT=test \
    -e ISUREAL_WORKERS=2 -e ISUREAL_IMAGE_CACHE_DIR=/tmp/c -e ISUREAL_INITIAL_IMAGE_CACHE_DIR=/tmp/ci ruby:4.0 \
    bash -c 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libturbojpeg0 >/dev/null 2>&1 && cp -r /src /webapp && cd /webapp/ruby && bundle install --quiet && exec bundle exec puma -C config/puma.rb' >/dev/null
}

wait_app() { for _ in $(seq 1 100); do curl -s -o /dev/null "localhost:$1/api/me" && return; sleep 3; done; echo "app on :$1 did not start" >&2; exit 1; }

old() {
  dir=$(mktemp -d)
  git archive "${1:-HEAD}" webapp/ruby | tar -x -C "$dir"
  run_app isutest-old 18081 "$dir/webapp"
  wait_app 18081
}

case "${1:-}" in
  up)
    docker network create isutest >/dev/null 2>&1 || true
    docker rm -f isutest-pg >/dev/null 2>&1 || true
    docker run -d --name isutest-pg --network isutest -e POSTGRES_USER=isureal -e POSTGRES_PASSWORD=isureal -e POSTGRES_DB=isureal postgres:16 >/dev/null
    sleep 5
    for f in 001-schema.sql 003-initial-snapshot.sql 002-indexes.sql 004-functions.sql; do psql_file "webapp/sql/$f" 2>&1 | grep -v NOTICE || true; done
    docker exec isutest-pg psql -q -U isureal -d isureal -c "INSERT INTO administrators (id, username, password_hash) VALUES (gen_random_uuid()::text, 'adm', encode(sha256('pw'), 'hex'))"
    run_app isutest-app 18080 "$root/webapp"
    old "${2:-HEAD}"
    wait_app 18080
    echo "new :18080 old :18081 ready (admin: adm / pw)"
    ;;
  reload)
    psql_file webapp/sql/002-indexes.sql 2>&1 | grep -v NOTICE || true
    psql_file webapp/sql/004-functions.sql
    docker exec isutest-app bash -c 'cp -r /src/ruby/lib /src/ruby/config /webapp/ruby/ && cp /src/ruby/config.ru /webapp/ruby/ && kill -USR2 1'
    sleep 8
    wait_app 18080
    echo reloaded
    ;;
  old) old "${2:?OLD_REV}" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
