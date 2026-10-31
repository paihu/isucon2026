#!/bin/bash
set -eu

hosts=(
  13.113.23.51
  13.112.188.233
  35.74.177.247
)

for h in "${hosts[@]}"; do
  echo "== $h"
  # ssh -o StrictHostKeyChecking=accept-new "isucon@$h" 'sudo systemctl disable --now isureal-go.service && sudo systemctl enable --now isureal-ruby.service && systemctl is-active isureal-ruby.service'
  ssh -A -o StrictHostKeyChecking=accept-new "isucon@$h" 'cd ~ && git fetch -q origin && git reset -q --hard origin/master && git log --oneline -1 && sudo systemctl restart isureal-ruby.service && sudo cp -r ~/etc/nginx/. /etc/nginx/ && sudo nginx -t -q && sudo rm -f /var/log/nginx/access.log /var/log/nginx/error.log && sudo systemctl reload nginx.service && systemctl is-active isureal-ruby.service nginx.service'
done
