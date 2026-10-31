# frozen_string_literal: true

# 初期データの画像を ImageCache::INITIAL_DIR に書き出す。既存ファイルは飛ばすので中断しても再実行できる。
# usage: set -a; . ~/env.sh; set +a; bundle exec ruby script/build_image_cache.rb

require 'fileutils'
require 'pg'

dir = ENV.fetch('ISUREAL_INITIAL_IMAGE_CACHE_DIR', File.expand_path('~/local/image-cache-initial'))
FileUtils.mkdir_p(dir)

conn = PG.connect(host: ENV.fetch('ISUREAL_DB_HOST', '127.0.0.1'), port: ENV.fetch('ISUREAL_DB_PORT', '5432'),
                  user: ENV.fetch('ISUREAL_DB_USER', 'isureal'), password: ENV.fetch('ISUREAL_DB_PASSWORD', 'isureal'),
                  dbname: ENV.fetch('ISUREAL_DB_NAME', 'isureal'))
conn.send_query_params(<<~SQL, [], 1)
  SELECT i.id, i.data FROM image_objects i, initial_data_boundary b WHERE i.created_at <= b.created_at
SQL
conn.set_single_row_mode

written = skipped = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
while (result = conn.get_result)
  result.check
  result.each_row do |id, data|
    path = File.join(dir, id)
    if !id.match?(/\A[0-9A-Za-z-]{1,64}\z/) || File.exist?(path)
      skipped += 1
      next
    end

    File.binwrite("#{path}.tmp", data)
    File.rename("#{path}.tmp", path)
    written += 1
    puts format('written=%d skipped=%d elapsed=%.0fs', written, skipped, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) if (written % 100_000).zero?
  end
end
puts format('done written=%d skipped=%d elapsed=%.0fs', written, skipped, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
