# frozen_string_literal: true

require 'securerandom'

module Isureal
  class App
    RELATIONSHIP_TARGET_REQUEST = {
      user_id: { param: 'userId' },
    }.freeze

    RELATIONSHIP_ERRORS = {
      'not_found' => [404, 'relationship_not_found'],
      'conflict' => [409, 'relationship_conflict'],
      'forbidden' => [403, 'relationship_action_forbidden'],
    }.freeze

    def change_relationship(action)
      input = bind(RELATIONSHIP_TARGET_REQUEST)
      actor = current_session.user_id
      raise APIError.new(400, 'invalid_relationship') if actor == input[:user_id] || input[:user_id].to_s.empty?

      result = db.get_value!('SELECT isureal_relationship($1, $2, $3, $4)', action, actor, input[:user_id], SecureRandom.uuid)
      error = RELATIONSHIP_ERRORS[result]
      raise APIError.new(*error) if error

      no_content(204)
    end

    def delete_friendship_handler = change_relationship('unfriend')

    def follow_handler = change_relationship('follow')

    def unfollow_handler = change_relationship('unfollow')

    def block_handler = change_relationship('block')

    def unblock_handler = change_relationship('unblock')
  end
end
