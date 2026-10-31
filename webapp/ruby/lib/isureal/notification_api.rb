# frozen_string_literal: true

require 'io/wait'

module Isureal
  # SSE の接続ごとに DB をポーリングしないよう、開いている投稿期間をプロセスで 1 つのスレッドが読み直す。
  class NotificationHub
    REFRESH_INTERVAL = 0.1

    Window = Data.define(:id, :region, :starts_at)

    def initialize(db)
      @db = db
      @windows = load_windows
      Thread.new { refresh_loop }
    end

    def active_window(region) = @windows[region]

    private

    def refresh_loop
      loop do
        sleep REFRESH_INTERVAL
        @windows = load_windows
      rescue StandardError => e
        Log.error('failed to reload posting windows', e.message)
      end
    end

    def load_windows
      @db.select('SELECT id, region, starts_at FROM posting_windows WHERE ended_at IS NULL').to_h { |row| [row[:region], Window.new(**row)] }
    end
  end

  class App
    NOTIFICATION_POLL_INTERVAL = 0.5
    # 退会やリージョン移動でストリームを閉じるための利用者の確認は、この回数のポーリングに 1 回にする。
    NOTIFICATION_USER_CHECK_TICKS = 10

    # 通知を行として保存しないのは、投稿期間の開始時にリージョンの全利用者分を INSERT すると数秒かかるため。
    # 開始時点で登録済みの利用者を対象とし、ID は（投稿期間, 利用者）から決定的に作る。
    NOTIFICATION_SQL = <<~SQL
      SELECT u.region AS user_region, n.id, n.posting_window_id, n.region, n.created_at
      FROM users u
      LEFT JOIN LATERAL (
        SELECT md5(w.id || ':' || u.id)::uuid::text AS id, w.id AS posting_window_id, w.region, w.starts_at AS created_at
        FROM posting_windows w
        WHERE w.region = u.region AND w.ended_at IS NULL AND w.starts_at > $2 AND u.created_at <= w.starts_at
        ORDER BY w.starts_at, w.id LIMIT 1
      ) n ON true
      WHERE u.id = $1 AND u.status = 'active'
    SQL

    def get_notifications_handler
      session = current_session
      user_id = session.user_id
      started = db.get!('SELECT clock_timestamp() AS connected_at, (SELECT created_at FROM users WHERE id = $1) AS user_created_at', user_id)
      status 200
      headers['content-type'] = 'text/event-stream'
      body(lambda do |stream|
        Thread.new do
          stream_notification(stream, session, user_id, started[:connected_at], started[:user_created_at])
        ensure
          begin
            stream.close
          rescue IOError, SystemCallError
            nil
          end
        end
      end)
    end

    def stream_notification(stream, session, user_id, connected_at, user_created_at)
      next_tick = monotonic_now + NOTIFICATION_POLL_INTERVAL
      ticks = 0
      loop do
        window = notification_hub.active_window(session.region)
        candidate = window && user_created_at && window.starts_at > connected_at && user_created_at <= window.starts_at
        if candidate || (ticks % NOTIFICATION_USER_CHECK_TICKS).zero?
          begin
            row = db.get(NOTIFICATION_SQL, user_id, connected_at)
          rescue StandardError => e
            Log.error('failed to get notification', e.message)
            return
          end
          return if row.nil? || row[:user_region] != session.region

          if row[:posting_window_id]
            data = Response.encode_json({
              id: row[:id], postingWindowId: row[:posting_window_id],
              region: row[:region], createdAt: Response.format_time(row[:created_at]),
            }).chomp
            stream.write("data: #{data}\n\n")
            return
          end
        end
        ticks += 1

        now = monotonic_now
        if now < next_tick
          return if stream.wait_readable(next_tick - now)

          next_tick += NOTIFICATION_POLL_INTERVAL
        else
          next_tick += NOTIFICATION_POLL_INTERVAL while next_tick <= now
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
