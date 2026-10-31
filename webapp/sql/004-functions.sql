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

  -- open_posting_window と競合すると 1 回目は 0 行になるので、新しいスナップショットで再取得する。
  SELECT * INTO w FROM posting_windows WHERE region = u.region AND ended_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    SELECT * INTO w FROM posting_windows WHERE region = u.region AND ended_at IS NULL FOR UPDATE;
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
CREATE OR REPLACE FUNCTION isureal_lock_pair(p_a text, p_b text) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM users WHERE users.id = least(p_a COLLATE "C", p_b) AND users.status = 'active' FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  PERFORM 1 FROM users WHERE users.id = greatest(p_a COLLATE "C", p_b) AND users.status = 'active' FOR NO KEY UPDATE;
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
     OR EXISTS (SELECT 1 FROM friendships f WHERE f.user_low_id = least(p_actor COLLATE "C", p_recipient)
                                              AND f.user_high_id = greatest(p_actor COLLATE "C", p_recipient)) THEN
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
    VALUES (p_friendship_id, least(p_actor COLLATE "C", p_recipient), greatest(p_actor COLLATE "C", p_recipient), existing.id);
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
    VALUES (p_friendship_id, least(request.requester_id COLLATE "C", request.recipient_id),
            greatest(request.requester_id COLLATE "C", request.recipient_id), request.id);
  END IF;
  UPDATE friend_requests r SET status = p_status, updated_at = clock_timestamp() WHERE r.id = request.id;

  RETURN QUERY SELECT 'ok'::text, r.id, r.status, r.updated_at FROM friend_requests r WHERE r.id = request.id;
END
$$;
