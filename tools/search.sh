#!/bin/bash
# usage: search.sh NEW_BASE OLD_BASE -> 同じユーザー集合に対する検索結果を新旧で並べて出力する（ユーザー作成は新コード側で行う）
N=$1; O=$2; j='content-type: application/json'; R=s$RANDOM
declare -A T I
names=("Straße Müller" "ＡＢＣ全角" "$(printf 'e\xcc\x81clair')" "ΣΊΣΥΦΟΣ" "小林 悠真" "Kelvin $(printf '\xe2\x84\xaa')" "Plain Name" "Blocked One")
for n in 0 1 2 3 4 5 6 7; do
  k=$(curl -s -XPOST $N/api/auth/register -H "$j" -d "$(gojq -nc --arg u "${R}_$n" --arg d "${names[$n]}" '{username:$u, displayName:$d, region:"asia"}')" | gojq -r .secretKey)
  r=$(curl -s -XPOST $N/api/auth/login -H "$j" -d "{\"username\":\"${R}_$n\",\"secretKey\":\"$k\"}"); T[$n]=$(echo "$r" | gojq -r .token); I[$n]=$(echo "$r" | gojq -r .user.id)
done
curl -s -o /dev/null -XPUT $N/api/blocks/${I[7]} -H "authorization: Bearer ${T[6]}"
curl -s -o /dev/null -XPATCH $N/api/me -H "authorization: Bearer ${T[4]}" -H "$j" -d '{"displayName":"Renamed ＳＴＲＡＳＳＥ"}'
q() { for b in $O $N; do curl -s -G "$b/api/users" -H "authorization: Bearer ${T[6]}" --data-urlencode "q=$1" "${@:2}" | gojq -c '[.items[] | .displayName] , .hasMore' | tr '\n' ' '; echo -n ' | '; done; echo; }
for s in "$R" strasse STRASSE ß Straße ａｂｃ ABC "$(printf '\xc3\xa9clair')" éclair σίσυφος ΣΊΣΥΦΟΣ ς 悠真 renamed kelvin k "blocked one" zzz; do echo -n "q=$s: "; q "$s"; done
first2=$(curl -s -G "$N/api/users" -H "authorization: Bearer ${T[6]}" --data-urlencode "q=$R" | gojq -r '.items[1] | "\(.username) \(.id)"')
echo -n "page after 2nd: "; q "$R" --data-urlencode "beforeUsername=${first2% *}" --data-urlencode "beforeId=${first2#* }"
