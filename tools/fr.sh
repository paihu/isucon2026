#!/bin/bash
# usage: fr.sh BASE  -> prints one line per step: code status
B=$1; j='content-type: application/json'; R=$RANDOM
declare -A T I
for n in a b c d e f g h i k x y; do
  k=$(curl -s -XPOST $B/api/auth/register -H "$j" -d "{\"username\":\"fr${R}$n\",\"displayName\":\"$n\",\"region\":\"asia\"}" | gojq -r .secretKey)
  r=$(curl -s -XPOST $B/api/auth/login -H "$j" -d "{\"username\":\"fr${R}$n\",\"secretKey\":\"$k\"}"); T[$n]=$(echo "$r" | gojq -r .token); I[$n]=$(echo "$r" | gojq -r .user.id)
done
req() { curl -s -w ' %{http_code}' -XPOST $B/api/friend-requests -H "authorization: Bearer ${T[$1]}" -H "$j" -d "{\"recipientId\":\"$2\"}"; }
act() { curl -s -w ' %{http_code}' -XPOST $B/api/friend-requests/$2/$3 -H "authorization: Bearer ${T[$1]}"; }
show() { echo "$1: $(echo "$2" | sed -E 's/"(relationId|updatedAt)":"[^"]*",?//g')"; }
show self "$(req a ${I[a]})"; show empty "$(req a '')"; show unknown "$(req a 00000000-0000-0000-0000-000000000000)"
r1=$(req a ${I[b]}); show a-b "$r1"; show a-b-again "$(req a ${I[b]})"
show b-a-mutual "$(req b ${I[a]})"; show a-b-after-friends "$(req a ${I[b]})"
r2=$(req c ${I[d]}); id2=$(echo ${r2% *} | gojq -r .relationId)
show d-cancel "$(act d $id2 cancel)"; show c-reject "$(act c $id2 reject)"; show c-accept "$(act c $id2 accept)"
show d-reject "$(act d $id2 reject)"; show d-reject-again "$(act d $id2 reject)"; show unknown-id "$(act d 00000000-0000-0000-0000-000000000000 accept)"; show bad-action "$(act d $id2 foo)"
r3=$(req e ${I[f]}); id3=$(echo ${r3% *} | gojq -r .relationId); show c-cancel-own "$(act e $id3 cancel)"
curl -s -o /dev/null -XPUT $B/api/blocks/${I[e]} -H "authorization: Bearer ${T[f]}"; show blocked-create "$(req e ${I[f]})"; show blocked-create-rev "$(req f ${I[e]})"
r4=$(req g ${I[h]}); id4=$(echo ${r4% *} | gojq -r .relationId); show h-accept "$(act h $id4 accept)"; show h-accept-again "$(act h $id4 accept)"
r5=$(req i ${I[k]}); id5=$(echo ${r5% *} | gojq -r .relationId); curl -s -o /dev/null -XPOST $B/api/me/account-deletion -H "authorization: Bearer ${T[k]}"; show cancel-after-deleted "$(act i $id5 cancel)"
echo "concurrent: $(for n in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w '%{http_code}\n' -XPOST $B/api/friend-requests -H "authorization: Bearer ${T[x]}" -H "$j" -d "{\"recipientId\":\"${I[y]}\"}" & done | sort | uniq -c | tr '\n' ' ')"; wait
echo "friendship order ok: $(docker exec isutest-pg psql -U isureal -d isureal -Atc "SELECT bool_and(user_low_id < user_high_id COLLATE \"C\") AND count(*) = 2 FROM friendships WHERE user_low_id IN ('${I[a]}','${I[b]}','${I[g]}','${I[h]}')")"
echo "friends list a: $(curl -s $B/api/relationships/friends -H "authorization: Bearer ${T[a]}" | gojq -c '[.items[].user.displayName]')"
