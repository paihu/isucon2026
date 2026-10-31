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
