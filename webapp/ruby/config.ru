# frozen_string_literal: true

# 2026-09-23

require_relative 'lib/isureal'

$stdout.sync = true

# multipart の一時ファイル（TMPDIR=/dev/shm でメモリ上にある）を GC 待ちにせず、応答後に消す。
use Rack::TempfileReaper

# ponytail: 計測用。GC の累計時間と回数を 5 秒ごとに書き出す。GC の調整を決めたら消す。
Thread.new do
  dir = '/dev/shm/isureal-gc'
  FileUtils.mkdir_p(dir)
  loop do
    sleep 5
    stat = GC.stat.slice(:time, :count, :minor_gc_count, :major_gc_count, :heap_live_slots, :total_allocated_objects)
    File.write("#{dir}/#{Process.pid}", "#{Time.now.utc.strftime('%H:%M:%S')} #{stat.map { |k, v| "#{k}=#{v}" }.join(' ')} rss_kb=#{File.read("/proc/#{Process.pid}/status")[/VmRSS:\s+(\d+)/, 1]}\n", mode: 'a')
  end
rescue StandardError
  nil
end
run Isureal.new_server(Isureal::Config.from_env, pool_size: Integer(ENV.fetch('ISUREAL_DB_POOL_SIZE', '15')))
