# frozen_string_literal: true

require 'securerandom'

module Isureal
  class App
    REACTION_TYPES = %w[like smile surprise heart laugh instant].freeze

    REPLACE_REAL_MOJI_REQUEST = {
      post_id: { param: 'postId' },
      image: { form: 'image', type: :file },
      reaction_type: { form: 'reactionType' },
    }.freeze

    GET_REAL_MOJIS_REQUEST = {
      post_id: { param: 'postId' },
      before_created_at: { query: 'beforeCreatedAt', type: :time },
      before_id: { query: 'beforeId' },
    }.freeze

    DELETE_REAL_MOJI_REQUEST = {
      real_moji_id: { param: 'realMojiId' },
    }.freeze

    def realmoji_response(reaction, user)
      {
        id: reaction.id, reactor: relationship_user_response(user), reactionType: reaction.reaction_type,
        imageUrl: ImageSignature.signed_url(user, reaction.image_id), createdAt: Response.format_time(reaction.created_at),
      }
    end

    def replace_real_moji_handler
      input = bind(REPLACE_REAL_MOJI_REQUEST)
      raise APIError.new(400, 'invalid_realmoji') if input[:image].nil?
      raise APIError.new(400, 'invalid_realmoji') unless REACTION_TYPES.include?(input[:reaction_type])

      input[:image].rewind
      data = input[:image].read
      image = JPEG.decode(data)
      raise APIError.new(400, 'invalid_realmoji') if image.nil?
      raise APIError.new(400, 'invalid_realmoji') if image.width > 512 || image.height > 512

      image_id = SecureRandom.uuid
      ImageCache.write(image_id, data)
      row = db.get!('SELECT * FROM isureal_replace_realmoji($1, $2, $3, $4, $5, $6, $7)',
                    current_user.id, input[:post_id], image_id, ''.b, SecureRandom.uuid, input[:reaction_type], ImageOrigin::SELF)
      raise_interaction_error(row[:result])

      reaction = RealMoji.from_row(row)
      user = current_user
      json_response(201, realmoji_response(reaction, user))
    end

    def get_real_mojis_handler
      input = bind(GET_REAL_MOJIS_REQUEST)
      raise APIError.new(400, 'invalid_pagination') if input[:before_created_at].nil? != input[:before_id].empty?
      allowed, rows = query_with_session(
        ['SELECT isureal_can_interact($1, $2, $3)', input[:post_id], 'view'],
        [current_realmojis_sql('AND r.post_id=$2 AND ($3::timestamptz IS NULL OR (r.created_at,r.id)<($3,$4)) ORDER BY r.created_at DESC,r.id DESC LIMIT 51'),
         input[:post_id], input[:before_created_at], input[:before_id]],
      )
      raise APIError.new(403, 'interaction_forbidden') unless allowed.getvalue(0, 0)

      reactions = realmojis_from_rows(rows)
      items = reactions.map { |reaction| realmoji_response(reaction, reaction.reactor) }
      has_more = items.length > 50
      items = items.first(50) if has_more
      json_response(200, { items:, hasMore: has_more })
    end

    def delete_real_moji_handler
      input = bind(DELETE_REAL_MOJI_REQUEST)
      raise_interaction_error(db.get_value!('SELECT isureal_delete_interaction($1, $2, $3)', 'realmoji', current_session.user_id, input[:real_moji_id]))
      no_content(204)
    end
  end
end
