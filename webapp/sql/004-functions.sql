-- 1 文の CTE にしないのは、同一ユーザーの同時ログインで後発の UPDATE が先発のセッションを見落とすため。
-- VOLATILE 関数内の各文は新しいスナップショットを取るので、元のトランザクションと同じ挙動になる。
CREATE OR REPLACE FUNCTION isureal_login(p_username text, p_secret_key_hash text, p_session_id text, p_token_hash text)
RETURNS TABLE (id varchar, username varchar, display_name text, bio text, profile_image_id varchar,
               region text, account_type text, status text)
LANGUAGE plpgsql AS $$
DECLARE
  u users;
BEGIN
  SELECT * INTO u FROM users WHERE users.username = p_username FOR NO KEY UPDATE;
  IF NOT FOUND OR u.status <> 'active' OR u.secret_key_hash <> p_secret_key_hash THEN
    RETURN;
  END IF;

  UPDATE login_sessions SET active = false, invalidated_at = clock_timestamp(), reason = 'replaced'
  WHERE login_sessions.user_id = u.id AND login_sessions.active = true;
  INSERT INTO login_sessions (id, user_id, token_hash) VALUES (p_session_id, u.id, p_token_hash);

  RETURN QUERY SELECT u.id, u.username, u.display_name, u.bio, u.profile_image_id, u.region, u.account_type, u.status;
END
$$;

-- 投稿枠が使えないときは 0 行を返す。
CREATE OR REPLACE FUNCTION isureal_create_post(p_user_id text, p_image_id text, p_image bytea, p_post_id text,
                                               p_caption text, p_visibility text, p_location_kind text,
                                               p_latitude numeric, p_longitude numeric, p_locality text)
RETURNS TABLE (id varchar, author_id varchar, posting_window_id varchar, image_id varchar, caption text,
               visibility text, location_kind text, latitude numeric, longitude numeric, locality text,
               posted_at timestamptz, on_time_deadline timestamptz, window_ended_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  u users;
  w posting_windows;
  active_count bigint;
  deleted_count bigint;
  now_ts timestamptz;
BEGIN
  SELECT * INTO u FROM users WHERE users.id = p_user_id FOR NO KEY UPDATE;
  IF NOT FOUND OR u.status <> 'active' THEN
    RAISE EXCEPTION 'sql: no rows in result set';
  END IF;

  -- 投稿期間の開始（同じキーの排他 advisory lock）を先に通す。行ロックの FOR SHARE だけだと、投稿が途切れない間
  -- 開始の UPDATE が排他ロックを取れず数秒待たされる。advisory lock は来た順に並ぶので、開始が待ち始めると後続の投稿はその後ろに並ぶ。
  PERFORM pg_advisory_xact_lock_shared(hashtext('posting_window:' || u.region));

  -- open_posting_window と競合すると 1 回目は 0 行になるので、新しいスナップショットで再取得する。
  -- FOR UPDATE にしないのは、同じリージョンの投稿同士がこの 1 行で直列になるため。FOR SHARE でも投稿期間の終了（UPDATE）とは競合する。
  SELECT * INTO w FROM posting_windows WHERE region = u.region AND ended_at IS NULL FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO w FROM posting_windows WHERE region = u.region AND ended_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RETURN;
    END IF;
  END IF;

  SELECT count(*) FILTER (WHERE p.deleted_at IS NULL), count(*) FILTER (WHERE p.deleted_at IS NOT NULL)
  INTO active_count, deleted_count
  FROM posts p JOIN posting_windows pw ON pw.id = p.posting_window_id
  WHERE p.author_id = p_user_id AND pw.local_date = w.local_date;
  now_ts := clock_timestamp();
  IF active_count <> 0 OR deleted_count >= 2 OR now_ts < w.starts_at THEN
    RETURN;
  END IF;

  INSERT INTO image_objects (id, owner_user_id, data, media_type, created_at)
  VALUES (p_image_id, p_user_id, p_image, 'image/jpeg', now_ts);
  INSERT INTO posts (id, author_id, posting_window_id, image_id, caption, visibility,
                     location_kind, latitude, longitude, locality, posted_at)
  VALUES (p_post_id, p_user_id, w.id, p_image_id, p_caption, p_visibility,
          p_location_kind, p_latitude, p_longitude, p_locality, now_ts);

  RETURN QUERY
  SELECT p.id, p.author_id, p.posting_window_id, p.image_id, p.caption, p.visibility,
         p.location_kind, p.latitude, p.longitude, p.locality, p.posted_at,
         pw.on_time_deadline, pw.ended_at
  FROM posts p JOIN posting_windows pw ON pw.id = p.posting_window_id
  WHERE p.id = p_post_id;
END
$$;

-- 友達申請の結果は result で返す: ok / not_found / forbidden / conflict。
-- ロック順と low/high は Ruby の String 比較（バイト順）に合わせるため COLLATE "C" で比較する。
-- 結果に COLLATE "default" を付けるのは、列と照合順序が食い違うとインデックスが使われないため。
CREATE OR REPLACE FUNCTION isureal_lock_pair(p_a text, p_b text) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM users WHERE users.id = (least(p_a COLLATE "C", p_b) COLLATE "default") AND users.status = 'active' FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  PERFORM 1 FROM users WHERE users.id = (greatest(p_a COLLATE "C", p_b) COLLATE "default") AND users.status = 'active' FOR NO KEY UPDATE;
  RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION isureal_create_friend_request(p_actor text, p_recipient text, p_request_id text, p_friendship_id text)
RETURNS TABLE (result text, id varchar, status text, updated_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  existing friend_requests;
  target_id text;
BEGIN
  IF NOT isureal_lock_pair(p_actor, p_recipient) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM block_relations b WHERE (b.blocker_id = p_actor AND b.blocked_id = p_recipient)
                                                OR (b.blocker_id = p_recipient AND b.blocked_id = p_actor))
     OR EXISTS (SELECT 1 FROM friendships f WHERE f.user_low_id = (least(p_actor COLLATE "C", p_recipient) COLLATE "default")
                                              AND f.user_high_id = (greatest(p_actor COLLATE "C", p_recipient) COLLATE "default")) THEN
    RETURN QUERY SELECT 'conflict'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT * INTO existing FROM friend_requests r
  WHERE r.status = 'pending' AND ((r.requester_id = p_actor AND r.recipient_id = p_recipient)
                               OR (r.requester_id = p_recipient AND r.recipient_id = p_actor))
  LIMIT 1;
  IF FOUND THEN
    IF existing.requester_id = p_actor THEN
      RETURN QUERY SELECT 'conflict'::text, NULL::varchar, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    UPDATE friend_requests r SET status = 'accepted', updated_at = clock_timestamp() WHERE r.id = existing.id;
    INSERT INTO friendships (id, user_low_id, user_high_id, source_request_id)
    VALUES (p_friendship_id, (least(p_actor COLLATE "C", p_recipient) COLLATE "default"), (greatest(p_actor COLLATE "C", p_recipient) COLLATE "default"), existing.id);
    target_id := existing.id;
  ELSE
    INSERT INTO friend_requests (id, requester_id, recipient_id, status, created_at, updated_at)
    VALUES (p_request_id, p_actor, p_recipient, 'pending', clock_timestamp(), clock_timestamp());
    target_id := p_request_id;
  END IF;

  RETURN QUERY SELECT 'ok'::text, r.id, r.status, r.updated_at FROM friend_requests r WHERE r.id = target_id;
END
$$;

CREATE OR REPLACE FUNCTION isureal_transition_friend_request(p_actor text, p_request_id text, p_status text, p_friendship_id text)
RETURNS TABLE (result text, id varchar, status text, updated_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  request friend_requests;
BEGIN
  SELECT * INTO request FROM friend_requests r WHERE r.id = p_request_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF (p_status = 'cancelled' AND p_actor <> request.requester_id) OR (p_status <> 'cancelled' AND p_actor <> request.recipient_id) THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT isureal_lock_pair(request.requester_id, request.recipient_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT * INTO request FROM friend_requests r WHERE r.id = p_request_id;
  IF request.status <> 'pending' THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF p_status = 'accepted' THEN
    IF EXISTS (SELECT 1 FROM block_relations b WHERE (b.blocker_id = request.requester_id AND b.blocked_id = request.recipient_id)
                                                  OR (b.blocker_id = request.recipient_id AND b.blocked_id = request.requester_id)) THEN
      RETURN QUERY SELECT 'conflict'::text, NULL::varchar, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    INSERT INTO friendships (id, user_low_id, user_high_id, source_request_id)
    VALUES (p_friendship_id, (least(request.requester_id COLLATE "C", request.recipient_id) COLLATE "default"),
            (greatest(request.requester_id COLLATE "C", request.recipient_id) COLLATE "default"), request.id);
  END IF;
  UPDATE friend_requests r SET status = p_status, updated_at = clock_timestamp() WHERE r.id = request.id;

  RETURN QUERY SELECT 'ok'::text, r.id, r.status, r.updated_at FROM friend_requests r WHERE r.id = request.id;
END
$$;

-- ViewerContext#can_view? / App#can_comment? と同じ判定。
CREATE OR REPLACE FUNCTION isureal_is_friend(p_a text, p_b text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM friendships f WHERE f.user_low_id = (least(p_a COLLATE "C", p_b) COLLATE "default") AND f.user_high_id = (greatest(p_a COLLATE "C", p_b) COLLATE "default"))
$$;

CREATE OR REPLACE FUNCTION isureal_has_posted_today(p_user text, p_region text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM posts p
    JOIN posting_windows posted ON posted.id = p.posting_window_id
    JOIN posting_windows current ON current.region = p_region AND current.ended_at IS NULL AND current.local_date = posted.local_date
    WHERE p.author_id = p_user AND p.deleted_at IS NULL
  )
$$;

-- mode: 'view' または 'comment'
CREATE OR REPLACE FUNCTION isureal_can_interact(p_viewer text, p_post_id text, p_mode text) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  post record;
  viewer users;
  posted_today boolean;
  can_view boolean;
BEGIN
  SELECT p.author_id, p.visibility, w.ended_at AS window_ended_at INTO post
  FROM posts p JOIN posting_windows w ON w.id = p.posting_window_id JOIN users u ON u.id = p.author_id AND u.status = 'active'
  WHERE p.id = p_post_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  SELECT * INTO viewer FROM users WHERE users.id = p_viewer AND users.status = 'active';
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  posted_today := isureal_has_posted_today(p_viewer, viewer.region);

  IF post.author_id = p_viewer THEN
    can_view := true;
  ELSIF post.window_ended_at IS NOT NULL OR NOT posted_today
        OR EXISTS (SELECT 1 FROM block_relations b WHERE (b.blocker_id = p_viewer AND b.blocked_id = post.author_id)
                                                     OR (b.blocker_id = post.author_id AND b.blocked_id = p_viewer)) THEN
    can_view := false;
  ELSIF post.visibility = 'public' THEN
    can_view := true;
  ELSIF post.visibility = 'friends' THEN
    can_view := isureal_is_friend(p_viewer, post.author_id);
  ELSIF post.visibility = 'friends_of_friends' THEN
    can_view := isureal_is_friend(p_viewer, post.author_id)
      OR EXISTS (SELECT 1 FROM friendships af WHERE af.user_low_id = post.author_id AND isureal_is_friend(p_viewer, af.user_high_id))
      OR EXISTS (SELECT 1 FROM friendships af WHERE af.user_high_id = post.author_id AND isureal_is_friend(p_viewer, af.user_low_id));
  ELSE
    can_view := false;
  END IF;

  IF p_mode = 'view' OR NOT can_view THEN
    RETURN can_view;
  END IF;
  IF post.window_ended_at IS NOT NULL THEN
    RETURN false;
  END IF;
  IF post.author_id = p_viewer THEN
    RETURN posted_today;
  END IF;
  RETURN post.visibility = 'public' OR isureal_is_friend(p_viewer, post.author_id);
END
$$;

-- action: follow / unfollow / block / unblock / unfriend。結果: ok / not_found / conflict / forbidden
CREATE OR REPLACE FUNCTION isureal_relationship(p_action text, p_actor text, p_target text, p_id text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  changed int;
BEGIN
  IF NOT isureal_lock_pair(p_actor, p_target) THEN
    RETURN 'not_found';
  END IF;

  IF p_action = 'unfriend' THEN
    DELETE FROM friendships f WHERE f.user_low_id = (least(p_actor COLLATE "C", p_target) COLLATE "default") AND f.user_high_id = (greatest(p_actor COLLATE "C", p_target) COLLATE "default");
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN CASE WHEN changed = 0 THEN 'conflict' ELSE 'ok' END;
  ELSIF p_action = 'follow' THEN
    IF (SELECT u.account_type FROM users u WHERE u.id = p_target) <> 'certified_public'
       OR EXISTS (SELECT 1 FROM block_relations b WHERE (b.blocker_id = p_actor AND b.blocked_id = p_target) OR (b.blocker_id = p_target AND b.blocked_id = p_actor))
       OR EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p_actor AND fo.followee_id = p_target) THEN
      RETURN 'conflict';
    END IF;
    INSERT INTO follows (id, follower_id, followee_id) VALUES (p_id, p_actor, p_target);
    RETURN 'ok';
  ELSIF p_action = 'unfollow' THEN
    DELETE FROM follows fo WHERE fo.follower_id = p_actor AND fo.followee_id = p_target;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN CASE WHEN changed = 0 THEN 'conflict' ELSE 'ok' END;
  ELSIF p_action = 'block' THEN
    IF EXISTS (SELECT 1 FROM block_relations b WHERE b.blocker_id = p_actor AND b.blocked_id = p_target) THEN
      RETURN 'conflict';
    END IF;
    INSERT INTO block_relations (id, blocker_id, blocked_id) VALUES (p_id, p_actor, p_target);
    DELETE FROM friendships f WHERE f.user_low_id = (least(p_actor COLLATE "C", p_target) COLLATE "default") AND f.user_high_id = (greatest(p_actor COLLATE "C", p_target) COLLATE "default");
    DELETE FROM follows fo WHERE (fo.follower_id = p_actor AND fo.followee_id = p_target) OR (fo.follower_id = p_target AND fo.followee_id = p_actor);
    UPDATE friend_requests r SET status = 'cancelled', updated_at = clock_timestamp()
    WHERE r.status = 'pending' AND ((r.requester_id = p_actor AND r.recipient_id = p_target) OR (r.requester_id = p_target AND r.recipient_id = p_actor));
    RETURN 'ok';
  ELSIF p_action = 'unblock' THEN
    DELETE FROM block_relations b WHERE b.blocker_id = p_actor AND b.blocked_id = p_target;
    GET DIAGNOSTICS changed = ROW_COUNT;
    RETURN CASE WHEN changed = 0 THEN 'forbidden' ELSE 'ok' END;
  END IF;
  RAISE EXCEPTION 'unknown relationship action: %', p_action;
END
$$;

-- 結果: ok / forbidden
CREATE OR REPLACE FUNCTION isureal_create_comment(p_actor text, p_post_id text, p_comment_id text, p_body text)
RETURNS TABLE (result text, id varchar, post_id varchar, author_id varchar, body text, created_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  post_author text;
BEGIN
  SELECT p.author_id INTO post_author FROM posts p WHERE p.id = p_post_id AND p.deleted_at IS NULL;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::varchar, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  PERFORM 1 FROM users u WHERE u.id = (least(p_actor COLLATE "C", post_author) COLLATE "default") FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sql: no rows in result set';
  END IF;
  IF p_actor <> post_author THEN
    PERFORM 1 FROM users u WHERE u.id = (greatest(p_actor COLLATE "C", post_author) COLLATE "default") FOR NO KEY UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sql: no rows in result set';
    END IF;
  END IF;
  IF NOT isureal_can_interact(p_actor, p_post_id, 'comment') THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::varchar, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO comments (id, post_id, author_id, body, created_at) VALUES (p_comment_id, p_post_id, p_actor, p_body, clock_timestamp());
  RETURN QUERY SELECT 'ok'::text, c.id, c.post_id, c.author_id, c.body, c.created_at FROM comments c WHERE c.id = p_comment_id;
END
$$;

-- 結果: ok / forbidden / relationship_not_found
CREATE OR REPLACE FUNCTION isureal_replace_realmoji(p_actor text, p_post_id text, p_image_id text, p_image bytea,
                                                    p_realmoji_id text, p_reaction_type text)
RETURNS TABLE (result text, id varchar, post_id varchar, reactor_id varchar, image_id varchar, reaction_type text, created_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  post_author text;
BEGIN
  SELECT p.author_id INTO post_author FROM posts p WHERE p.id = p_post_id AND p.deleted_at IS NULL;
  IF NOT FOUND OR post_author = p_actor THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::varchar, NULL::varchar, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT isureal_lock_pair(p_actor, post_author) THEN
    RETURN QUERY SELECT 'relationship_not_found'::text, NULL::varchar, NULL::varchar, NULL::varchar, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT isureal_can_interact(p_actor, p_post_id, 'view') THEN
    RETURN QUERY SELECT 'forbidden'::text, NULL::varchar, NULL::varchar, NULL::varchar, NULL::varchar, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  UPDATE realmojis r SET replaced_at = clock_timestamp()
  WHERE r.post_id = p_post_id AND r.reactor_id = p_actor AND r.replaced_at IS NULL AND r.deleted_at IS NULL;
  INSERT INTO image_objects (id, owner_user_id, data, media_type) VALUES (p_image_id, p_actor, p_image, 'image/jpeg');
  INSERT INTO realmojis (id, post_id, reactor_id, image_id, reaction_type, created_at)
  VALUES (p_realmoji_id, p_post_id, p_actor, p_image_id, p_reaction_type, clock_timestamp());
  RETURN QUERY SELECT 'ok'::text, r.id, r.post_id, r.reactor_id, r.image_id, r.reaction_type, r.created_at FROM realmojis r WHERE r.id = p_realmoji_id;
END
$$;

-- kind: comment / realmoji。結果: ok / not_found / forbidden
CREATE OR REPLACE FUNCTION isureal_delete_interaction(p_kind text, p_actor text, p_id text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  owner_id text;
  post_author text;
BEGIN
  PERFORM 1 FROM users u WHERE u.id = p_actor FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sql: no rows in result set';
  END IF;
  IF p_kind = 'comment' THEN
    SELECT c.author_id, p.author_id INTO owner_id, post_author
    FROM comments c JOIN posts p ON p.id = c.post_id WHERE c.id = p_id AND c.deleted_at IS NULL FOR UPDATE OF c;
  ELSE
    SELECT r.reactor_id, p.author_id INTO owner_id, post_author
    FROM realmojis r JOIN posts p ON p.id = r.post_id WHERE r.id = p_id AND r.deleted_at IS NULL FOR UPDATE OF r;
  END IF;
  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;
  IF p_actor <> owner_id AND p_actor <> post_author THEN
    RETURN 'forbidden';
  END IF;
  IF p_kind = 'comment' THEN
    UPDATE comments c SET deleted_at = clock_timestamp() WHERE c.id = p_id;
  ELSE
    UPDATE realmojis r SET deleted_at = clock_timestamp() WHERE r.id = p_id;
  END IF;
  RETURN 'ok';
END
$$;
