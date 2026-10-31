# frozen_string_literal: true

require 'securerandom'

module Isureal
  class App
    CREATE_COMMENT_REQUEST = {
      post_id: { param: 'postId' },
      body: { json: 'body' },
    }.freeze

    GET_COMMENTS_REQUEST = {
      post_id: { param: 'postId' },
      after_created_at: { query: 'afterCreatedAt', type: :time },
      after_id: { query: 'afterId' },
    }.freeze

    DELETE_COMMENT_REQUEST = {
      comment_id: { param: 'commentId' },
    }.freeze

    def comment_response(comment, user)
      { id: comment.id, author: relationship_user_response(user), body: comment.body, createdAt: Response.format_time(comment.created_at) }
    end

    def create_comment_handler
      input = bind(CREATE_COMMENT_REQUEST)
      raise APIError.new(400, 'invalid_interaction') unless valid_user_text?(input[:body], 1, 1000)

      row = db.get!('SELECT * FROM isureal_create_comment($1, $2, $3, $4)', current_user.id, input[:post_id], SecureRandom.uuid, input[:body])
      raise_interaction_error(row[:result])

      json_response(201, comment_response(Comment.from_row(row), current_user))
    end

    def get_comments_handler
      input = bind(GET_COMMENTS_REQUEST)
      raise APIError.new(400, 'invalid_pagination') if input[:after_created_at].nil? != input[:after_id].empty?
      allowed, rows = query_with_session(
        ['SELECT isureal_can_interact($1, $2, $3)', input[:post_id], 'comment'],
        [comments_with_author_sql('AND c.post_id=$2 AND ($3::timestamptz IS NULL OR (c.created_at,c.id)>($3,$4)) ORDER BY c.created_at,c.id LIMIT 51'),
         input[:post_id], input[:after_created_at], input[:after_id]],
      )
      raise APIError.new(403, 'interaction_forbidden') unless allowed.getvalue(0, 0)

      comments = comments_from_rows(rows)
      items = comments.map { |comment| comment_response(comment, comment.author) }
      has_more = items.length > 50
      items = items.first(50) if has_more
      json_response(200, { items:, hasMore: has_more })
    end

    def delete_comment_handler
      input = bind(DELETE_COMMENT_REQUEST)
      raise_interaction_error(db.get_value!('SELECT isureal_delete_interaction($1, $2, $3)', 'comment', current_session.user_id, input[:comment_id]))
      no_content(204)
    end
  end
end
