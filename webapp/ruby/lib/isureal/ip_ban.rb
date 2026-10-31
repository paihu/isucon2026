# frozen_string_literal: true

module Isureal
  # リクエスト中に読み直さないのは、europe/america では読み直しの 1 往復（約 100ms）をそのリクエストが待つため。
  class IPBanList
    RELOAD_INTERVAL = 0.05

    def initialize(db)
      @db = db
      @bans = load_ip_bans
      Thread.new { reload_loop }
    end

    def banned?(ip)
      banned_until = @bans[ip]
      !banned_until.nil? && Time.now < banned_until
    end

    private

    def reload_loop
      loop do
        sleep RELOAD_INTERVAL
        @bans = load_ip_bans
      rescue StandardError => e
        Log.error('failed to reload ip bans', e.message)
      end
    end

    def load_ip_bans
      @db.select('SELECT ip, banned_until FROM ip_bans WHERE banned_until > clock_timestamp()').to_h { |row| [row[:ip], row[:banned_until]] }
    end
  end

  module IPBan
    def self.extract_client_ip(env)
      ip = env['HTTP_X_CLIENT_IP']
      ip = env['REMOTE_ADDR'] if ip.nil? || ip.empty?
      (ip || '').dup.force_encoding(Encoding::UTF_8).scrub
    end
  end

  class App
    def ip_ban_middleware
      raise APIError.new(403, 'ip_banned') if ip_bans.banned?(real_ip)
    end

    def real_ip = IPBan.extract_client_ip(env)
  end
end
