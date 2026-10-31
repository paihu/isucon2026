DROP INDEX IF EXISTS users_username;
CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON users(username);
-- ユーザー検索用に Ruby で正規化した名前（App::SearchText）。登録・表示名変更・初期化で埋める。
ALTER TABLE users ADD COLUMN IF NOT EXISTS search_username text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS search_display_name text;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS users_search_username_trgm ON users USING gin (search_username gin_trgm_ops);
CREATE INDEX IF NOT EXISTS users_search_display_name_trgm ON users USING gin (search_display_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS login_sessions_token_hash ON login_sessions(token_hash);
CREATE INDEX IF NOT EXISTS login_sessions_user_id ON login_sessions(user_id);
CREATE INDEX IF NOT EXISTS administrator_sessions_token_hash ON administrator_sessions(token_hash);
-- 友達判定（user_low_id と user_high_id の両方が決まる）を 1 件の参照で済ませるため、user_high_id 単独ではなく複合にする。
-- 単独の索引だと、閲覧者が user_high_id 側に来たときに閲覧者の交友関係を全部読んでから絞っていた。
CREATE INDEX IF NOT EXISTS friendships_user_high_id_user_low_id ON friendships(user_high_id, user_low_id);
DROP INDEX IF EXISTS friendships_user_high_id;
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
-- 画像の有効性確認で ID から引く表。image_objects は created_at でパーティション分割されていて、ID だけで引くと
-- 全パーティションの索引を総当たりするため。image_objects の行トリガで同期し、初期化（トリガが動かない）では reset.sql で消す。
CREATE OR REPLACE FUNCTION isureal_sync_image_meta() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO image_meta (id, owner_user_id, media_type, created_at)
    VALUES (NEW.id, NEW.owner_user_id, NEW.media_type, NEW.created_at)
    ON CONFLICT (id) DO NOTHING;
  ELSE
    DELETE FROM image_meta WHERE id = OLD.id;
  END IF;
  RETURN NULL;
END
$$;
DO $$
BEGIN
  IF to_regclass('image_meta') IS NULL THEN
    CREATE TABLE image_meta (
      id varchar(36) PRIMARY KEY,
      owner_user_id varchar(36) NOT NULL,
      media_type text NOT NULL,
      created_at timestamptz NOT NULL
    );
    -- 既存行を写す間に挿入されたものを取りこぼさないよう、トリガを作るまで image_objects への書き込みを止める。
    LOCK TABLE image_objects IN SHARE MODE;
    INSERT INTO image_meta (id, owner_user_id, media_type, created_at)
    SELECT id, owner_user_id, media_type, created_at FROM image_objects
    ON CONFLICT (id) DO NOTHING;
    CREATE TRIGGER image_objects_sync_meta AFTER INSERT OR DELETE ON image_objects
    FOR EACH ROW EXECUTE FUNCTION isureal_sync_image_meta();
  END IF;
END
$$;
