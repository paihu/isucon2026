# frozen_string_literal: true

require 'digest'

module Isureal
  Session = Struct.new(:user, :token_hash, keyword_init: true) do
    def user_id = user.id

    def region = user.region
  end

  class App
    SESSION_SQL = <<~SQL
      SELECT #{USER_COLUMNS.map { |column| %(u.#{column} AS "user.#{column}") }.join(', ')}
      FROM login_sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = $1
        AND s.active = true AND u.status = 'active'
    SQL

    # query_with_session で送る SQL の $1（利用者 ID）をこれに置き換え、$1 にはトークンのハッシュを渡す。
    SESSION_USER_ID_SQL = <<~SQL.gsub(/\s+/, ' ').strip
      (SELECT s.user_id FROM login_sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = $1 AND s.active = true AND u.status = 'active' LIMIT 1)
    SQL

    def current_session
      env.fetch('isureal.session') { env['isureal.session'] = session_from_header }
    end

    def current_user = current_session.user

    def token_hash_from_header
      auth_header = env['HTTP_AUTHORIZATION']
      return nil if auth_header.nil? || auth_header.empty?

      unless auth_header.start_with?('Bearer ')
        Log.warn('Invalid authorization header format(not started with Bearer)')
        raise APIError.new(401, 'invalid_session')
      end

      Digest::SHA256.hexdigest(auth_header.delete_prefix('Bearer '))
    end

    def session_from_header
      token_hash = token_hash_from_header
      token_hash && session_from_row(db.get(SESSION_SQL, token_hash), token_hash)
    end

    def session_from_row(row, token_hash)
      row && Session.new(user: User.from_row(row, 'user').set_image_key, token_hash:)
    end

    def session_middleware(auth_required)
      session = current_session
      raise APIError.new(401, 'invalid_session') if session.nil? && auth_required

      yield
    end

    # europe/america ではセッション確認だけで 1 往復（約 100ms）かかるので、GET では確認を最初の読み取りと
    # 同じ往復（query_with_session）に載せる。それより前に失敗したときは、従来どおり 401/403 を優先する。
    def deferred_session_middleware
      yield
    rescue StandardError
      verify_session_region unless env.key?('isureal.session')
      raise
    end

    def verify_session_region
      session = current_session
      raise APIError.new(401, 'invalid_session') if session.nil?
      raise APIError.new(403, 'region_mismatch') if session.region != config.region
    end

    TEXT_OID = 25

    # queries は [sql, *params]。各 SQL の $1 は利用者 ID、params は $2 以降。
    # $1 を使わない SQL でも型が決まるよう、トークンのハッシュは text と明示する。
    def query_with_session(*queries)
      token_hash = token_hash_from_header
      raise APIError.new(401, 'invalid_session') if token_hash.nil?

      token_param = { value: token_hash, type: TEXT_OID }

      session_result, *results = db.pipeline([
        [SESSION_SQL, [token_hash]],
        *queries.map { |sql, *params| [sql.gsub(/\$1(?!\d)/, SESSION_USER_ID_SQL), [token_param, *params]] },
      ])
      env['isureal.session'] = session_from_row(session_result.first, token_hash)
      verify_session_region
      results
    end

    def invalidate_login_session(user_id, token_hash)
      db.exec(<<~SQL, user_id, token_hash)
        UPDATE login_sessions
        SET active = false, invalidated_at = clock_timestamp(), reason = 'logout'
        WHERE user_id = $1 AND active = true AND token_hash = $2
      SQL
    end
  end
end
