# frozen_string_literal: true

RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

port 8080
environment 'production'
workers Integer(ENV.fetch('ISUREAL_WORKERS', '2'))
threads_count = Integer(ENV.fetch('ISUREAL_THREADS', '16'))
threads threads_count, threads_count
# DB 接続を worker ごとに起動時に張るため、親プロセスでアプリを読み込まない。
preload_app! false
