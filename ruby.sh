#!/bin/bash
set -eu

# asia1 の nginx が asia2 にも振り分けるので、asia2 を先に更新する。
app_only_hosts=(
  175.41.248.35
)
hosts=(
  13.113.23.51
  13.112.188.233
  35.74.177.247
)

deploy_app='cd ~ && git fetch -q origin && git reset -q --hard origin/master && git log --oneline -1 && gcc -O2 -shared -fPIC -o ~/webapp/ruby/ext/iterated_hmac.so ~/webapp/ruby/ext/iterated_hmac.c -lcrypto && rm -rf ~/local/image-cache /dev/shm/isureal-image-state && sudo systemctl restart isureal-ruby.service'

for h in "${app_only_hosts[@]}"; do
  echo "== $h"
  ssh -A -o StrictHostKeyChecking=accept-new "isucon@$h" "$deploy_app"' && systemctl is-active isureal-ruby.service isureal-guard.service'
done

for h in "${hosts[@]}"; do
  echo "== $h"
  # ssh -o StrictHostKeyChecking=accept-new "isucon@$h" 'sudo systemctl disable --now isureal-go.service && sudo systemctl enable --now isureal-ruby.service && systemctl is-active isureal-ruby.service'
  ssh -A -o StrictHostKeyChecking=accept-new "isucon@$h" "$deploy_app"' && sudo cp ~/etc/systemd/isureal-ruby-admin.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable -q isureal-ruby-admin.service && sudo systemctl restart isureal-ruby-admin.service && sudo cp -r ~/etc/nginx/. /etc/nginx/ && . ~/env.sh && upstream=/etc/nginx/upstream/$ISUREAL_REGION.conf && { [ -f "$upstream" ] || upstream=/etc/nginx/upstream/default.conf; } && sudo cp "$upstream" /etc/nginx/conf.d/isureal-upstream.conf && sudo nginx -t -q && sudo rm -f /var/log/nginx/access.log /var/log/nginx/error.log && sudo systemctl reload nginx.service && systemctl is-active isureal-ruby.service isureal-ruby-admin.service nginx.service'
done
