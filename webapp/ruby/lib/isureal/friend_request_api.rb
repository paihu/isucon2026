# frozen_string_literal: true

require 'securerandom'

module Isureal
  class App
    CREATE_FRIEND_REQUEST_REQUEST = {
      recipient_id: { json: 'recipientId' },
    }.freeze

    TRANSITION_FRIEND_REQUEST_REQUEST = {
      request_id: { param: 'requestId' },
      action: { param: 'action' },
    }.freeze

    FRIEND_REQUEST_TRANSITIONS = {
      'accept' => 'accepted',
      'reject' => 'rejected',
      'cancel' => 'cancelled',
    }.freeze

    def friend_request_response(request)
      { relationId: request.id, status: request.status, updatedAt: Response.format_time(request.updated_at) }
    end

    FRIEND_REQUEST_ERRORS = {
      'not_found' => [404, 'relationship_not_found'],
      'forbidden' => [403, 'relationship_action_forbidden'],
      'conflict' => [409, 'relationship_conflict'],
    }.freeze

    def friend_request_from_result(row)
      error = FRIEND_REQUEST_ERRORS[row[:result]]
      raise APIError.new(*error) if error

      FriendRequest.new(id: row[:id], status: row[:status], updated_at: row[:updated_at])
    end

    def create_friend_request_handler
      input = bind(CREATE_FRIEND_REQUEST_REQUEST)
      actor = current_session.user_id
      recipient_id = input[:recipient_id]
      raise APIError.new(400, 'invalid_relationship') if actor == recipient_id || recipient_id.to_s.empty?

      row = db.get!('SELECT * FROM isureal_create_friend_request($1, $2, $3, $4)', actor, recipient_id, SecureRandom.uuid, SecureRandom.uuid)
      json_response(201, friend_request_response(friend_request_from_result(row)))
    end

    def transition_friend_request_handler
      input = bind(TRANSITION_FRIEND_REQUEST_REQUEST)
      status = FRIEND_REQUEST_TRANSITIONS[input[:action]]
      raise APIError.new(403, 'relationship_action_forbidden') if status.nil?

      row = db.get!('SELECT * FROM isureal_transition_friend_request($1, $2, $3, $4)',
                    current_session.user_id, input[:request_id], status, SecureRandom.uuid)
      json_response(200, friend_request_response(friend_request_from_result(row)))
    end
  end
end
