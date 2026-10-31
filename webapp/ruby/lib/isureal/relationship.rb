# frozen_string_literal: true

require 'securerandom'

module Isureal
  FriendRequest = Struct.new(:id, :requester_id, :recipient_id, :status, :created_at, :updated_at, keyword_init: true)
end
