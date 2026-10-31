#!/bin/bash
# 旧コード(:18081)と新コード(:18080)に同じ GET を投げ、署名/期限以外の差分を比較する
set -u
NEW=localhost:18080; OLD=localhost:18081; j='content-type: application/json'
JPG=/usr/share/doc/libsndfile/libsndfile.jpg
psql_() { docker exec isutest-pg psql -q -U isureal -d isureal -Atc "$1"; }
R=$RANDOM
declare -A TOK ID
for n in 1 2 3 4 5 6 7 8; do
  u="cmp${R}_$n"
  k=$(curl -s -XPOST $NEW/api/auth/register -H "$j" -d "{\"username\":\"$u\",\"displayName\":\"U$n\",\"region\":\"asia\"}" | gojq -r .secretKey)
  r=$(curl -s -XPOST $NEW/api/auth/login -H "$j" -d "{\"username\":\"$u\",\"secretKey\":\"$k\"}")
  TOK[$n]=$(echo "$r" | gojq -r .token); ID[$n]=$(echo "$r" | gojq -r .user.id)
done
fr() { psql_ "INSERT INTO friendships (id,user_low_id,user_high_id) SELECT gen_random_uuid()::text, least('${ID[$1]}','${ID[$2]}'), greatest('${ID[$1]}','${ID[$2]}')"; }
fr 1 2; fr 2 3; fr 3 4; fr 1 5; fr 5 3; fr 2 6
psql_ "INSERT INTO block_relations (id,blocker_id,blocked_id) VALUES (gen_random_uuid()::text,'${ID[1]}','${ID[7]}')"
psql_ "UPDATE users SET account_type='certified_public' WHERE id='${ID[8]}'"
psql_ "UPDATE users SET bio='bio' WHERE username LIKE 'cmp${R}_%'"
psql_ "INSERT INTO follows (id,follower_id,followee_id) VALUES (gen_random_uuid()::text,'${ID[1]}','${ID[8]}')"
psql_ "UPDATE posting_windows SET ended_at=clock_timestamp() WHERE region='asia' AND ended_at IS NULL; INSERT INTO posting_windows (id,region,local_date,starts_at,on_time_deadline) VALUES (gen_random_uuid()::text,'asia',CURRENT_DATE+(SELECT count(*) FROM posting_windows)::int,clock_timestamp(),clock_timestamp()+interval '1 hour')"
declare -A POST
vis=([1]=friends [2]=friends [3]=friends_of_friends [4]=public [5]=friends_of_friends [6]=public [7]=public [8]=public)
for n in 1 2 3 4 5 6 7 8; do
  POST[$n]=$(curl -s -XPOST $NEW/api/posts -H "authorization: Bearer ${TOK[$n]}" -F image=@$JPG -F caption=p$n -F visibility=${vis[$n]} -F location_kind=none | gojq -r .id)
done
c() { curl -s -o /dev/null -w "comment $1->$2 %{http_code}\n" -XPOST $NEW/api/posts/${POST[$2]}/comments -H "authorization: Bearer ${TOK[$1]}" -H "$j" -d '{"body":"hi"}'; }
m() { curl -s -o /dev/null -w "realmoji $1->$2 %{http_code}\n" -XPOST $NEW/api/posts/${POST[$2]}/realmojis -H "authorization: Bearer ${TOK[$1]}" -F image=@$JPG -F reactionType=like; }
c 2 3; c 5 3; m 5 3; m 2 4; c 6 2
strip() { gojq 'walk(if type == "string" then sub("\\?exp=[0-9]+&sig=[A-Za-z0-9_-]+"; "") else . end)'; }
diffs=0; total=0
for v in 1 2 3 5 7; do
  paths=(/api/feeds/friends /api/feeds/friends-of-friends /api/feeds/public /api/feeds/following /api/me /api/posts/me/current)
  for n in 1 2 3 4 5 6 7 8; do paths+=(/api/posts/${POST[$n]} /api/posts/${POST[$n]}/comments /api/posts/${POST[$n]}/realmojis /api/users/${ID[$n]}); done
  for p in "${paths[@]}"; do
    a=$(curl -s -w '\n%{http_code}' $OLD$p -H "authorization: Bearer ${TOK[$v]}"); b=$(curl -s -w '\n%{http_code}' $NEW$p -H "authorization: Bearer ${TOK[$v]}")
    total=$((total+1))
    if [ "$(echo "$a" | head -n -1 | strip)|$(echo "$a" | tail -1)" != "$(echo "$b" | head -n -1 | strip)|$(echo "$b" | tail -1)" ]; then
      diffs=$((diffs+1)); echo "DIFF viewer=u$v $p"; diff <(echo "$a" | head -n -1 | strip) <(echo "$b" | head -n -1 | strip) | head -10
    fi
  done
  echo "u$v friends-of-friends feed: $(curl -s $NEW/api/feeds/friends-of-friends -H "authorization: Bearer ${TOK[$v]}" | gojq -c '[.items[] | {c: .caption, s: .score}]')"
done
echo "compared=$total diffs=$diffs"
