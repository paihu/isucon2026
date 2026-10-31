DROP INDEX IF EXISTS users_username;
CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON users(username);
-- ユーザー検索用に Ruby で正規化した名前（App::SearchText）。登録・表示名変更・初期化で埋める。
ALTER TABLE users ADD COLUMN IF NOT EXISTS search_username text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS search_display_name text;
CREATE INDEX IF NOT EXISTS login_sessions_token_hash ON login_sessions(token_hash);
CREATE INDEX IF NOT EXISTS login_sessions_user_id ON login_sessions(user_id);
CREATE INDEX IF NOT EXISTS administrator_sessions_token_hash ON administrator_sessions(token_hash);
CREATE INDEX IF NOT EXISTS friendships_user_high_id ON friendships(user_high_id);
CREATE INDEX IF NOT EXISTS follows_followee_id ON follows(followee_id);
CREATE INDEX IF NOT EXISTS block_relations_blocked_id ON block_relations(blocked_id);
CREATE INDEX IF NOT EXISTS friend_requests_pending_pair ON friend_requests(requester_id, recipient_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS friend_requests_pending_recipient ON friend_requests(recipient_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS posts_image_id ON posts(image_id);
CREATE INDEX IF NOT EXISTS realmojis_image_id ON realmojis(image_id);
CREATE INDEX IF NOT EXISTS notifications_user_id_created_at ON notifications(user_id, created_at);
-- JPEG は圧縮できないので、TOAST の圧縮を試みない。
ALTER TABLE image_objects ALTER COLUMN data SET STORAGE EXTERNAL;
-- 画像本体を DB に置かない画像の、本体を持つサーバー（host:port）。
ALTER TABLE image_objects ADD COLUMN IF NOT EXISTS origin text;
