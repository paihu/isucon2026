# frozen_string_literal: true

module Isureal
  class App
    FEEDS = %w[friends friends-of-friends public following].freeze

    GET_FEED_REQUEST = {
      feed: { param: 'feed' },
      before_score: { query: 'beforeScore', type: :int },
      before_posted_at: { query: 'beforePostedAt', type: :time },
      before_id: { query: 'beforeId' },
    }.freeze

    FEED_CONDITIONS = <<~SQL
      AND p.author_id <> $1 AND w.ended_at IS NULL
      AND ($2::timestamptz IS NULL OR (p.posted_at, p.id) < ($2, $3))
      ORDER BY p.posted_at DESC, p.id DESC
    SQL

    # 開いている投稿期間の全投稿は数百行になるので、種類ごとの条件で先に絞る。最終的な判定は matches_feed? が行う。
    # IN (友達一覧) や IN (フォロー先) にしないのは、友達・フォロー先の全期間の投稿から結合する計画になり秒単位で遅くなるため。
    FEED_FILTERS = {
      'friends' => <<~SQL,
        AND EXISTS (
          SELECT 1 FROM friendships f
          WHERE f.user_low_id = (least(p.author_id COLLATE "C", $1) COLLATE "default")
            AND f.user_high_id = (greatest(p.author_id COLLATE "C", $1) COLLATE "default")
        )
      SQL
      'public' => "AND p.visibility = 'public'",
      'following' => 'AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id)',
    }.freeze
    # friends-of-friends を絞らないのは、投稿ごとに投稿者の交友関係を総当たりする計画になり、友達の多い利用者で 300ms を超えたため。
    # friends は友達本人、public は公開範囲だけで見えるので、友達の友達（取得が重い）を判定に使わない。
    FEEDS_WITHOUT_FRIENDS_OF_FRIENDS = %w[friends public].freeze

    def get_feed_handler
      input = bind(GET_FEED_REQUEST)
      raise APIError.new(400, 'invalid_post') unless FEEDS.include?(input[:feed])
      raise APIError.new(400, 'invalid_pagination') if input[:before_posted_at].nil? != input[:before_id].empty?

      ranked = input[:feed] == 'friends-of-friends'
      raise APIError.new(400, 'invalid_pagination') if ranked && input[:before_score].nil? != input[:before_id].empty?

      before_posted_at, before_id = ranked ? [nil, ''] : input.values_at(:before_posted_at, :before_id)
      viewer_rows, post_rows = query_with_session([FEEDS_WITHOUT_FRIENDS_OF_FRIENDS.include?(input[:feed]) ? VIEWER_CONTEXT_WITHOUT_FOF_SQL : VIEWER_CONTEXT_SQL], [posts_with_author_sql("#{FEED_FILTERS[input[:feed]]}\n#{FEED_CONDITIONS}"), before_posted_at, before_id], prepare: true)
      viewer = viewer_context(current_user, viewer_rows.first)
      following = viewer.following
      posts = posts_from_rows(post_rows)
      candidates = posts.select { |post| viewer.can_view?(post) && matches_feed?(viewer, following, post, input[:feed]) }
      scores = {}
      if ranked
        scores = recommendation_scores(db, viewer, candidates)
        candidates = candidates.sort_by.with_index { |post, index| [-scores[post.id], index] }
      end
      items = []
      candidates.each do |post|
        score = scores[post.id]
        next if ranked && !input[:before_score].nil? && !ranked_before?(score, post, *input.values_at(:before_score, :before_posted_at, :before_id))

        item = post_response(post, post.author)
        item[:score] = score if ranked
        items << item
        break if items.length == 51
      end
      has_more = items.length > 50
      items = items.first(50) if has_more
      json_response(200, { items:, hasMore: has_more })
    end

    def ranked_before?(score, post, before_score, before_posted_at, before_id)
      return score < before_score if score != before_score
      return post.posted_at < before_posted_at if post.posted_at != before_posted_at

      post.id < before_id
    end

    RECOMMENDATION_SQL = <<~SQL
      SELECT
        ARRAY(
          SELECT ARRAY[user_low_id, user_high_id] FROM friendships
          WHERE user_low_id = ANY($1::text[]) OR user_high_id = ANY($1::text[])
        )::text[] AS friendships,
        ARRAY(
          SELECT ARRAY[post_id, user_id] FROM (
            SELECT r.post_id, r.reactor_id AS user_id FROM realmojis r
            JOIN users u ON u.id = r.reactor_id AND u.status = 'active'
            WHERE r.post_id = ANY($2::text[]) AND r.replaced_at IS NULL AND r.deleted_at IS NULL
            UNION
            SELECT c.post_id, c.author_id AS user_id FROM comments c
            JOIN users u ON u.id = c.author_id AND u.status = 'active'
            WHERE c.post_id = ANY($2::text[]) AND c.deleted_at IS NULL
          ) e
        )::text[] AS engagements
    SQL

    def recommendation_scores(db, viewer, posts)
      return {} if posts.empty?

      row = db.get!(RECOMMENDATION_SQL, posts.map(&:author_id), posts.map(&:id))
      connections = Hash.new(0)
      row[:friendships].each do |low, high|
        connections[low] += viewer.mutual_friends[high]
        connections[high] += viewer.mutual_friends[low]
      end

      friend_engagements = Hash.new(0)
      row[:engagements].each do |post_id, user_id|
        friend_engagements[post_id] += 1 if viewer.friends[user_id]
      end

      posts.to_h do |post|
        [post.id, (10 * friend_engagements[post.id]) + (3 * viewer.mutual_friends[post.author_id]) + [connections[post.author_id], 30].min]
      end
    end

    def matches_feed?(viewer, following, post, feed)
      case feed
      when 'public' then post.visibility == 'public'
      when 'following' then following[post.author_id]
      when 'friends' then viewer.friends[post.author_id]
      when 'friends-of-friends' then !viewer.friends[post.author_id] && viewer.friends_of_friends[post.author_id]
      else false
      end
    end
  end
end
