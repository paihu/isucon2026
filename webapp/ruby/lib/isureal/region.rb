# frozen_string_literal: true

module Isureal
  class App
    def region_middleware
      verify_session_region
      yield
    end
  end
end
