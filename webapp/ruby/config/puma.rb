# frozen_string_literal: true

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

port Integer(ENV.fetch('ISUREAL_PORT', '8080'))
environment 'production'
workers Integer(ENV.fetch('ISUREAL_WORKERS', '2'))
# europe/america は DB 往復（約 100ms）の待ちが大半で CPU が空いているので、スレッドと DB 接続を多めにする。
default_threads = %w[europe america].include?(ENV['ISUREAL_REGION']) ? 32 : 16
threads_count = Integer(ENV.fetch('ISUREAL_THREADS', default_threads.to_s))
threads threads_count, threads_count
ENV['ISUREAL_DB_POOL_SIZE'] ||= (threads_count - 1).to_s
# DB 接続を worker ごとに起動時に張るため、親プロセスでアプリを読み込まない。
preload_app! false
# 大きなリクエスト本文の一時ファイルをディスクに書かないため（不正な画像アップロードで asia1 が I/O 待ちになっていた）。
ENV['TMPDIR'] = '/dev/shm' if File.writable?('/dev/shm')
