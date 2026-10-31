# frozen_string_literal: true

module Isureal
  COMMENT_FIELDS = %i[id post_id author_id body created_at deleted_at].freeze

  Comment = Struct.new(*COMMENT_FIELDS, :author, keyword_init: true) do
    def self.from_row(row)
      new(**row.slice(*COMMENT_FIELDS))
    end
  end

  class App
    def comments_with_author_sql(conditions)
      <<~SQL
        SELECT c.id, c.post_id, c.author_id, c.body, c.created_at, c.deleted_at, #{user_columns_as('u', 'author')}
        FROM comments c #{active_user_lateral('u', 'c.author_id')}
        WHERE c.deleted_at IS NULL #{conditions}
      SQL
    end

    def select_comments_with_author(db, conditions, *args) = comments_from_rows(db.select(comments_with_author_sql(conditions), *args))

    def comments_from_rows(rows)
      rows.map { |row| Comment.from_row(row).tap { |comment| comment.author = User.from_row(row, 'author').set_image_key } }
    end

    INTERACTION_ERRORS = {
      'forbidden' => [403, 'interaction_forbidden'],
      'not_found' => [404, 'interaction_not_found'],
      'relationship_not_found' => [404, 'relationship_not_found'],
    }.freeze

    def raise_interaction_error(result)
      error = INTERACTION_ERRORS[result]
      raise APIError.new(*error) if error
    end

    # mode: 'view'（投稿を閲覧できるか）または 'comment'（コメントできるか）
    def can_interact?(post_id, mode)
      db.get_value!('SELECT isureal_can_interact($1, $2, $3)', current_session.user_id, post_id, mode)
    end
  end
end
