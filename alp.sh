#!/bin/bash
# usage: ./alp.sh [alp に追加で渡すオプション...]   例: ./alp.sh --sort avg
set -eu

hosts=(
  asia1:35.74.177.247
  europe1:13.113.23.51
  america1:13.112.188.233
)

matching='/api/images/.+,/api/posts/me/current,/api/posts/[^/]+/comments,/api/posts/[^/]+/realmojis,/api/posts/[^/]+$,/api/users/.+,/api/memories/.+,/api/friend-requests/.+,/api/follows/.+,/api/blocks/.+,/api/comments/.+,/api/realmojis/.+,/api/friendships/.+,/api/relationships/.+,/api/feeds/.+,/api/admin/users/.+'

dir="local/alp/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$dir"

for entry in "${hosts[@]}"; do
  scp -q "isucon@${entry#*:}:/var/log/nginx/access.log" "$dir/${entry%%:*}.log"
done

for entry in "${hosts[@]}"; do
  name=${entry%%:*}
  echo "=== $name ($(wc -l < "$dir/$name.log") requests)"
  alp ltsv --file "$dir/$name.log" -m "$matching" --sort sum -r \
    -o count,method,uri,min,avg,p90,max,sum,max_body,2xx,4xx,5xx --format tsv "$@" | column -t -s $'\t'
  echo
done | tee "$dir/summary.txt"

echo "logs: $dir"
