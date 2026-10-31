#!/bin/bash
# usage: ix.sh BASE -> status codes for interaction / relationship scenarios
B=$1; j='content-type: application/json'; JPG=/usr/share/doc/libsndfile/libsndfile.jpg; R=$RANDOM
psql_() { docker exec isutest-pg psql -q -U isureal -d isureal -Atc "$1"; }
declare -A T I P
for n in 1 2 3 4 5 6 7 8 9; do
  k=$(curl -s -XPOST $B/api/auth/register -H "$j" -d "{\"username\":\"ix${R}_$n\",\"displayName\":\"U$n\",\"region\":\"asia\"}" | gojq -r .secretKey)
  r=$(curl -s -XPOST $B/api/auth/login -H "$j" -d "{\"username\":\"ix${R}_$n\",\"secretKey\":\"$k\"}"); T[$n]=$(echo "$r" | gojq -r .token); I[$n]=$(echo "$r" | gojq -r .user.id)
done
fr() { psql_ "INSERT INTO friendships (id,user_low_id,user_high_id) SELECT gen_random_uuid()::text, least('${I[$1]}','${I[$2]}' COLLATE \"C\"), greatest('${I[$1]}','${I[$2]}' COLLATE \"C\")"; }
win() { psql_ "UPDATE posting_windows SET ended_at=clock_timestamp() WHERE region='asia' AND ended_at IS NULL; INSERT INTO posting_windows (id,region,local_date,starts_at,on_time_deadline) VALUES (gen_random_uuid()::text,'asia',CURRENT_DATE+(SELECT count(*) FROM posting_windows)::int,clock_timestamp(),clock_timestamp()+interval '1 hour')"; }
post() { curl -s -XPOST $B/api/posts -H "authorization: Bearer ${T[$1]}" -F image=@$JPG -F caption=p$1 -F visibility=$2 -F location_kind=none | gojq -r .id; }
fr 1 2; fr 2 3; fr 3 4; fr 1 5; fr 5 3; fr 2 6
psql_ "UPDATE users SET account_type='certified_public' WHERE id='${I[8]}'"
win; P[9]=$(post 9 public); win
vis=([1]=friends [2]=friends [3]=friends_of_friends [4]=public [5]=friends_of_friends [6]=public [7]=public [8]=public)
for n in 1 2 3 4 5 6 7 8; do P[$n]=$(post $n ${vis[$n]}); done
curl -s -o /dev/null -XPUT $B/api/blocks/${I[7]} -H "authorization: Bearer ${T[1]}"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
echo "-- interactions (viewer: post -> comment realmoji listC listR)"
for v in 1 2 3 4 5 6 7 9; do line="v$v:"; for n in 1 2 3 4 5 6 7 8 9; do
  c=$(code -XPOST $B/api/posts/${P[$n]}/comments -H "authorization: Bearer ${T[$v]}" -H "$j" -d '{"body":"hi"}')
  m=$(code -XPOST $B/api/posts/${P[$n]}/realmojis -H "authorization: Bearer ${T[$v]}" -F image=@$JPG -F reactionType=like)
  lc=$(code $B/api/posts/${P[$n]}/comments -H "authorization: Bearer ${T[$v]}"); lr=$(code $B/api/posts/${P[$n]}/realmojis -H "authorization: Bearer ${T[$v]}")
  line="$line p$n=$c/$m/$lc/$lr"; done; echo "$line"; done
echo "unknown post: $(code -XPOST $B/api/posts/nope/comments -H "authorization: Bearer ${T[1]}" -H "$j" -d '{"body":"x"}')/$(code -XPOST $B/api/posts/nope/realmojis -H "authorization: Bearer ${T[1]}" -F image=@$JPG -F reactionType=like)/$(code $B/api/posts/nope/comments -H "authorization: Bearer ${T[1]}")"
cid=$(curl -s -XPOST $B/api/posts/${P[2]}/comments -H "authorization: Bearer ${T[1]}" -H "$j" -d '{"body":"x"}' | gojq -r .id)
mid=$(curl -s -XPOST $B/api/posts/${P[2]}/realmojis -H "authorization: Bearer ${T[1]}" -F image=@$JPG -F reactionType=smile | gojq -r .id)
echo "delete comment by stranger/author-of-post/again/unknown: $(code -XDELETE $B/api/comments/$cid -H "authorization: Bearer ${T[4]}") $(code -XDELETE $B/api/comments/$cid -H "authorization: Bearer ${T[2]}") $(code -XDELETE $B/api/comments/$cid -H "authorization: Bearer ${T[1]}") $(code -XDELETE $B/api/comments/nope -H "authorization: Bearer ${T[1]}")"
echo "delete realmoji by stranger/owner/again: $(code -XDELETE $B/api/realmojis/$mid -H "authorization: Bearer ${T[4]}") $(code -XDELETE $B/api/realmojis/$mid -H "authorization: Bearer ${T[1]}") $(code -XDELETE $B/api/realmojis/$mid -H "authorization: Bearer ${T[1]}")"
rel() { code -X$1 $B/api/$2/$3 -H "authorization: Bearer ${T[$4]}"; }
echo "-- relationships"
echo "follow noncert/cert/again/unfollow/again: $(rel PUT follows ${I[4]} 2) $(rel PUT follows ${I[8]} 2) $(rel PUT follows ${I[8]} 2) $(rel DELETE follows ${I[8]} 2) $(rel DELETE follows ${I[8]} 2)"
echo "follow self/unknown: $(rel PUT follows ${I[2]} 2) $(rel PUT follows 00000000-0000-0000-0000-000000000000 2)"
echo "block/again/follow-blocked/unblock/again: $(rel PUT blocks ${I[8]} 3) $(rel PUT blocks ${I[8]} 3) $(rel PUT follows ${I[8]} 3) $(rel DELETE blocks ${I[8]} 3) $(rel DELETE blocks ${I[8]} 3)"
echo "unfriend/again/not-friend: $(rel DELETE friendships ${I[6]} 2) $(rel DELETE friendships ${I[6]} 2) $(rel DELETE friendships ${I[9]} 2)"
curl -s -o /dev/null -XPOST $B/api/friend-requests -H "authorization: Bearer ${T[4]}" -H "$j" -d "{\"recipientId\":\"${I[6]}\"}"; curl -s -o /dev/null -XPUT $B/api/follows/${I[8]} -H "authorization: Bearer ${T[4]}"
echo "block with friendship+request+follow: $(rel PUT blocks ${I[3]} 4) $(rel PUT blocks ${I[6]} 4) $(rel PUT blocks ${I[8]} 4) -> friends=$(psql_ "SELECT count(*) FROM friendships WHERE '${I[4]}' IN (user_low_id,user_high_id)") pending=$(psql_ "SELECT count(*) FROM friend_requests WHERE status='pending' AND requester_id='${I[4]}'") follows=$(psql_ "SELECT count(*) FROM follows WHERE follower_id='${I[4]}'")"
curl -s -o /dev/null -XPOST $B/api/me/account-deletion -H "authorization: Bearer ${T[9]}"; echo "follow/block deleted user: $(rel PUT follows ${I[9]} 2) $(rel PUT blocks ${I[9]} 2)"
