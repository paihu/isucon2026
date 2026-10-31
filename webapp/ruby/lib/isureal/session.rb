# frozen_string_literal: true

require 'digest'

module Isureal
  Session = Struct.new(:user, :token_hash, keyword_init: true) do
    def user_id = user.id

    def region = user.region
  end

  class App
    def current_session = env['isureal.session']

    def current_user = current_session.user

    def session_from_header
      auth_header = env['HTTP_AUTHORIZATION']
      return nil if auth_header.nil? || auth_header.empty?

      unless auth_header.start_with?('Bearer ')
        Log.warn('Invalid authorization header format(not started with Bearer)')
        raise APIError.new(401, 'invalid_session')
      end

      token = auth_header.delete_prefix('Bearer ')
      token_hash = Digest::SHA256.hexdigest(token)
      row = db.get(<<~SQL, token_hash)
        SELECT #{user_columns_as('u', 'user')}
        FROM login_sessions s JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = $1
          AND s.active = true AND u.status = 'active'
      SQL
      row && Session.new(user: User.from_row(row, 'user').set_image_key, token_hash:)
    end

    def session_middleware(auth_required)
      session = session_from_header
      raise APIError.new(401, 'invalid_session') if session.nil? && auth_required

      env['isureal.session'] = session
      yield
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
