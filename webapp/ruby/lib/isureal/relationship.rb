# frozen_string_literal: true

require 'securerandom'

module Isureal
  FriendRequest = Struct.new(:id, :requester_id, :recipient_id, :status, :created_at, :updated_at, keyword_init: true)

  class App
    def blocked?(db, actor, target)
      db.get_value!('SELECT EXISTS(SELECT 1 FROM block_relations WHERE (blocker_id=$1 AND blocked_id=$2) OR (blocker_id=$2 AND blocked_id=$1))', actor, target)
    end
  end
end
