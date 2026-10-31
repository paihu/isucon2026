# frozen_string_literal: true

module Isureal
  POST_FIELDS = %i[id author_id posting_window_id image_id caption visibility location_kind latitude longitude locality
                   posted_at on_time_deadline window_ended_at].freeze

  Post = Struct.new(*POST_FIELDS, :author, keyword_init: true) do
    def self.from_row(row)
      new(**row.slice(*POST_FIELDS))
    end

    def location
      { kind: location_kind, latitude:, longitude:, locality: }.compact
    end
  end

  module PostLocation
    module_function

    def valid?(kind:, latitude:, longitude:, locality:)
      case kind
      when 'none'
        latitude.nil? && longitude.nil? && locality.nil?
      when 'exact'
        !latitude.nil? && !longitude.nil? && locality.nil? &&
          latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
      when 'approximate'
        latitude.nil? && longitude.nil? && !locality.nil? && UserValidation.valid_user_text?(locality, 1, 100)
      else
        false
      end
    end
  end

  ViewerContext = Struct.new(:user, :has_posted_today, :friends, :friends_of_friends, :mutual_friends, :blocked,
                             :following, keyword_init: true) do
    def id = user.id

    def region = user.region

    def can_view?(post)
      return true if post.author_id == id
      return false if !post.window_ended_at.nil? || !has_posted_today || blocked[post.author_id]

      case post.visibility
      when 'public' then true
      when 'friends' then friends[post.author_id]
      when 'friends_of_friends' then friends[post.author_id] || friends_of_friends[post.author_id]
      else false
      end
    end
  end

  class App
    POST_COLUMNS = <<~SQL.chomp
      p.id, p.author_id, p.posting_window_id, p.image_id, p.caption, p.visibility,
        p.location_kind, p.latitude, p.longitude, p.locality, p.posted_at,
        w.on_time_deadline, w.ended_at AS window_ended_at
    SQL

    def in_placeholders(start, count)
      (start...(start + count)).map { |i| "$#{i}" }.join(', ')
    end

    def get_post(db, post_id)
      row = db.get(<<~SQL, post_id)
        SELECT #{POST_COLUMNS}
        FROM posts p JOIN posting_windows w ON w.id = p.posting_window_id
        WHERE p.id = $1 AND p.deleted_at IS NULL
      SQL
      row && Post.from_row(row)
    end

    def posts_with_author_sql(conditions)
      <<~SQL
        SELECT #{POST_COLUMNS}, #{user_columns_as('u', 'author')}
        FROM posts p
        JOIN posting_windows w ON w.id = p.posting_window_id
        JOIN users u ON u.id = p.author_id AND u.status = 'active'
        WHERE p.deleted_at IS NULL #{conditions}
      SQL
    end

    def posts_from_rows(rows)
      rows.map { |row| Post.from_row(row).tap { |post| post.author = User.from_row(row, 'author').set_image_key } }
    end

    VIEWER_CONTEXT_TEMPLATE = <<~SQL
      WITH friends AS (
        SELECT CASE WHEN user_low_id = $1 THEN user_high_id ELSE user_low_id END AS id
        FROM friendships WHERE user_low_id = $1 OR user_high_id = $1
      )
      SELECT
        EXISTS(
          SELECT 1 FROM posts p
          JOIN posting_windows posted ON posted.id = p.posting_window_id
          JOIN posting_windows current ON current.region = (SELECT region FROM users WHERE id = $1) AND current.ended_at IS NULL
                                      AND current.local_date = posted.local_date
          WHERE p.author_id = $1 AND p.deleted_at IS NULL
        ) AS has_posted_today,
        ARRAY(
          SELECT CASE WHEN blocker_id = $1 THEN blocked_id ELSE blocker_id END
          FROM block_relations WHERE blocker_id = $1 OR blocked_id = $1
        )::text[] AS blocked,
        ARRAY(SELECT id FROM friends)::text[] AS friends,
        %s AS friend_friendships,
        ARRAY(SELECT followee_id FROM follows WHERE follower_id = $1)::text[] AS following
    SQL
    VIEWER_CONTEXT_SQL = format(VIEWER_CONTEXT_TEMPLATE, <<~SQL.chomp)
      ARRAY(
          SELECT ARRAY[f.user_low_id, f.user_high_id] FROM friends fr JOIN friendships f ON f.user_low_id = fr.id
          UNION
          SELECT ARRAY[f.user_low_id, f.user_high_id] FROM friends fr JOIN friendships f ON f.user_high_id = fr.id
        )::text[]
    SQL
    # 友達の友達（友達の交友関係の総当たり）は友達が多いと 10ms 以上かかるので、判定に使わない画面では取らない。
    VIEWER_CONTEXT_WITHOUT_FOF_SQL = format(VIEWER_CONTEXT_TEMPLATE, 'ARRAY[]::text[]')

    def viewer_context(user, row)
      viewer = ViewerContext.new(user:, friends: {}, friends_of_friends: {}, mutual_friends: Hash.new(0))
      viewer.has_posted_today = row[:has_posted_today]
      viewer.blocked = row[:blocked].to_h { |id| [id, true] }
      viewer.following = row[:following].to_h { |id| [id, true] }
      row[:friends].each { |id| viewer.friends[id] = true }
      row[:friend_friendships].each do |low, high|
        if viewer.friends[low]
          viewer.friends_of_friends[high] = true
          viewer.mutual_friends[high] += 1 if high != viewer.id
        end
        if viewer.friends[high]
          viewer.friends_of_friends[low] = true
          viewer.mutual_friends[low] += 1 if low != viewer.id
        end
      end
      viewer
    end
  end
end
