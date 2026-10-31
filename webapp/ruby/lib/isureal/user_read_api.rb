# frozen_string_literal: true

module Isureal
  class App
    SEARCH_USERS_REQUEST = {
      q: { query: 'q' },
      before_username: { query: 'beforeUsername' },
      before_id: { query: 'beforeId' },
    }.freeze

    GET_USER_REQUEST = {
      user_id: { param: 'userId' },
    }.freeze

    SEARCH_USERS_SQL = <<~SQL
      SELECT #{USER_COLUMNS.map { |column| "u.#{column}" }.join(', ')}
      FROM users u
      WHERE u.status = 'active' AND u.id <> $1 AND ($2 = '' OR (u.username, u.id) > ($2, $3))
        AND (u.search_username LIKE $4 OR u.search_display_name LIKE $4)
        AND NOT EXISTS (SELECT 1 FROM block_relations b WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1))
      ORDER BY u.username, u.id LIMIT 51
    SQL

    def search_users_handler
      input = bind(SEARCH_USERS_REQUEST)
      raise APIError.new(400, 'invalid_relationship') unless valid_user_text?(input[:q], 1, 100)
      raise APIError.new(400, 'invalid_pagination') if input[:before_username].empty? != input[:before_id].empty?

      users, = query_with_session([SEARCH_USERS_SQL, input[:before_username], input[:before_id], "%#{SearchText.normalize(input[:q]).gsub(/[\\%_]/) { |char| "\\#{char}" }}%"])
      items = users.map do |row|
        user = User.from_row(row).set_image_key
        user.bio = '' if user.account_type != 'certified_public'
        relationship_user_response(user)
      end
      has_more = items.length > 50
      items = items.first(50) if has_more
      json_response(200, { items:, hasMore: has_more })
    end

    def get_user_handler
      input = bind(GET_USER_REQUEST)
      viewer = current_session.user_id
      user = get_user(db, input[:user_id])
      raise APIError.new(404, 'relationship_not_found') if user.nil?
      raise APIError.new(404, 'relationship_not_found') if blocked?(db, viewer, user.id)

      friends = get_friend_ids(db, viewer)
      user.bio = '' if user.account_type != 'certified_public' && !friends.include?(user.id)
      json_response(200, relationship_user_response(user))
    end

    def relationship_user_response(user)
      {
        id: user.id, username: user.username, displayName: user.display_name,
        profileImageUrl: profile_image_url(user), bio: user.bio, accountType: user.account_type,
      }
    end
  end
end
