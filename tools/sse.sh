#!/bin/bash
B=$1; j="content-type: application/json"; R=$RANDOM; O=$(mktemp -d)
AT=$(curl -s -XPOST $B/api/admin/auth/login -H "$j" -d '{"username":"adm","password":"pw"}' | gojq -r .token)
reg() { k=$(curl -s -XPOST $B/api/auth/register -H "$j" -d "{\"username\":\"ss${R}$1\",\"displayName\":\"$1\",\"region\":\"asia\"}" | gojq -r .secretKey); curl -s -XPOST $B/api/auth/login -H "$j" -d "{\"username\":\"ss${R}$1\",\"secretKey\":\"$k\"}" | gojq -r .token; }
D=$(docker exec isutest-pg psql -U isureal -d isureal -Atc "SELECT greatest(max(local_date), CURRENT_DATE) + 1 FROM posting_windows")
open() { curl -s -o $O/open-$1.json -w '%{http_code}' -XPOST $B/api/admin/posting-window -H "authorization: Bearer $AT" -H "$j" -d "{\"region\":\"$1\",\"localDate\":\"$2\"}"; }
A=$(reg a)
timeout 3 curl -sN $B/api/notifications -H "authorization: Bearer $A" > $O/a1.txt & sleep 0.5
echo "open europe: $(open europe $D)"; sleep 1.2
echo "open asia: $(open asia $D)"; wait
C=$(reg c)
timeout 2 curl -sN $B/api/notifications -H "authorization: Bearer $C" > $O/c.txt
timeout 2 curl -sN $B/api/notifications -H "authorization: Bearer $A" > $O/a2.txt
WID=$(gojq -r .id $O/open-asia.json)
echo "A got: $(sed -n 's/^data: //p' $O/a1.txt | gojq -c --arg w "$WID" '{id_is_uuid: (.id|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")), window_matches: (.postingWindowId == $w), region, createdAt_eq_startsAt: true}')"
echo "A createdAt==window.startsAt: $([ "$(sed -n 's/^data: //p' $O/a1.txt | gojq -r .createdAt)" = "$(gojq -r .startsAt $O/open-asia.json)" ] && echo yes || echo no)"
echo "C (registered after open): '$(cat $O/c.txt)'  A reconnect: '$(cat $O/a2.txt)'"
echo "A event count in first stream: $(grep -c '^data:' $O/a1.txt)"
