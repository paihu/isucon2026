#!/bin/bash
# 旧コード（:18081）と新コード（:18080）の応答を突き合わせる。tools/local-env.sh up 済みが前提。
cd "$(dirname "$0")"
out=$(mktemp -d)
for t in fr ix sse; do
  bash "$t.sh" localhost:18081 > "$out/$t-old.txt" 2>&1
  bash "$t.sh" localhost:18080 > "$out/$t-new.txt" 2>&1
  if diff -q "$out/$t-old.txt" "$out/$t-new.txt" >/dev/null; then echo "$t: IDENTICAL"; else echo "$t: DIFF"; diff "$out/$t-old.txt" "$out/$t-new.txt" | head -20; fi
done
bash compare.sh 2>&1 | tail -1
echo "new app 5xx: $(docker logs isutest-app 2>&1 | grep -c '"status":5')"
