#!/bin/bash
# ベンチ計測。asia1・asia2（DB+app）・europe1・america1 で vmstat / pidstat を記録し、pg_stat_statements を集計する。
# usage:
#   tools/monitor.sh start              # 30 分間の記録を開始し pg_stat_statements をリセット（デプロイ後・ベンチ前に実行）
#   tools/monitor.sh report FROM TO     # ベンチ区間（HH:MM:SS、UTC）の CPU・I/O・DB 上位クエリを表示
set -eu
cd "$(dirname "$0")"
hosts=(35.74.177.247 175.41.248.35 13.113.23.51 13.112.188.233)
db=175.41.248.35

case "${1:-}" in
  start)
    for h in "${hosts[@]}"; do
      # pkill -f は自分の ssh コマンド行にも一致するので -x で名前一致にする。
      ssh -n "isucon@$h" 'pkill -x vmstat; pkill -x pidstat
        setsid -f timeout 1800 vmstat -t 1 > ~/local/vmstat.log 2>&1 < /dev/null
        setsid -f timeout 1800 pidstat -u -h -l 1 > ~/local/pidstat.log 2>&1 < /dev/null
        setsid -f timeout 1800 pidstat -d -h -l 1 > ~/local/pidstat-io.log 2>&1 < /dev/null
        echo "$(hostname): recording until $(date -u -d "+30 min" +%H:%M)"'
    done
    ssh -n "isucon@$db" 'sudo -u postgres psql -At -d isureal -c "SELECT pg_stat_statements_reset()" >/dev/null && echo pg_stat_statements reset'
    ;;
  report)
    from=${2:?FROM}; to=${3:?TO}
    for h in "${hosts[@]}"; do
      echo "== $h ($from-$to)"
      ssh -n "isucon@$h" "awk -v f=$from -v t=$to '\$NF >= f && \$NF <= t {n++; us+=\$13; sy+=\$14; id+=\$15; wa+=\$16; if (\$15 <= 5) busy++}
          END {printf \"vmstat us=%.0f sy=%.0f idle=%.0f wa=%.0f secs_idle<=5%%=%d/%d\n\", us/n, sy/n, id/n, wa/n, busy, n}' ~/local/vmstat.log
        awk -v f=$from -v t=$to '!/^#/ && \$1 >= f && \$1 <= t && NF >= 10 {c = \$10; if (c ~ /postgres/) c = \"postgres\"; else if (c ~ /puma/) c = \"puma\"; s[c] += \$8; if (!(\$1 in seen)) {seen[\$1]; n++}}
          END {for (k in s) if (s[k]/n > 2) printf \"  cpu %6.1f%% %s\n\", s[k]/n, k}' ~/local/pidstat.log | sort -k2 -rn
        awk -v f=$from -v t=$to '!/^#/ && \$1 >= f && \$1 <= t && NF >= 8 {c = \$8; if (c ~ /postgres/) c = \"postgres\"; else if (c ~ /puma/) c = \"puma\"; rd[c] += \$4; wr[c] += \$5; if (!(\$1 in seen)) {seen[\$1]; n++}}
          END {for (k in rd) if (rd[k] + wr[k] > n) printf \"  io read %.2fMB/s write %.2fMB/s %s\n\", rd[k]/n/1024, wr[k]/n/1024, k}' ~/local/pidstat-io.log"
    done
    echo "== pg_stat_statements (since last reset)"
    ssh "isucon@$db" 'sudo -u postgres psql -d isureal -f -' < pss-top.sql
    ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
