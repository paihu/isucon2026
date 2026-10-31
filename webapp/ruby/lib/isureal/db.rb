# frozen_string_literal: true

require 'connection_pool'
require 'date'
require 'pg'

module Isureal
  class Database
    def initialize(options, size:, timeout: 60)
      PG.connect(**options).close
      @pool = ConnectionPool.new(size:, timeout:) { Connection.new(PG.connect(**options)) }
      prewarm(size)
    end

    # europe/america では新規接続に数往復かかるので、起動時に全接続を張っておく。
    def prewarm(size)
      acquired = Queue.new
      release = Queue.new
      threads = Array.new(size) do
        Thread.new do
          @pool.with do
            acquired << true
            release.pop
          end
        end
      end
      size.times { acquired.pop }
      size.times { release << true }
      threads.each(&:join)
    end

    def with
      @pool.with do |conn|
        yield conn
      rescue PG::ConnectionBad, PG::UnableToSend
        @pool.discard_current_connection(&:close)
        raise
      end
    end

    def get(...) = with { |conn| conn.get(...) }

    def get!(...) = with { |conn| conn.get!(...) }

    def get_value(...) = with { |conn| conn.get_value(...) }

    def get_value!(...) = with { |conn| conn.get_value!(...) }

    def select(...) = with { |conn| conn.select(...) }

    def select_values(...) = with { |conn| conn.select_values(...) }

    def exec(...) = with { |conn| conn.exec(...) }

    def transaction(&) = with { |conn| conn.transaction(&) }

    def pipeline(queries) = with { |conn| conn.pipeline(queries) }
  end

  class Connection
    ARRAY_ENCODER = PG::TextEncoder::Array.new
    TYPE_REGISTRY = PG::BasicTypeRegistry.new.register_default_types
                                         .register_type(0, 'numeric', PG::TextEncoder::Float, PG::TextDecoder::Float)
    # パーティションを総当たりする SQL は計画に 1ms 以上かかるので、接続時に prepare して計画を使い回す。
    PREPARED = {}

    def self.prepare_on_connect(*sqls)
      sqls.each { |sql| PREPARED[sql] ||= "isureal_p#{PREPARED.size + 1}" }
    end

    def initialize(raw)
      @raw = raw
      @raw.type_map_for_results = PG::BasicTypeMapForResults.new(@raw, registry: TYPE_REGISTRY)
      @raw.field_name_type = :symbol
      PREPARED.each { |sql, name| @raw.prepare(name, sql) }
    end

    def get(sql, *params) = query(sql, params).first

    def get!(sql, *params) = get(sql, *params) || raise(NoRowsError)

    def get_value(sql, *params)
      result = query(sql, params)
      result.ntuples.zero? ? nil : result.getvalue(0, 0)
    end

    def get_value!(sql, *params)
      result = query(sql, params)
      raise NoRowsError if result.ntuples.zero?

      result.getvalue(0, 0)
    end

    def select(sql, *params) = query(sql, params).to_a

    def select_values(sql, *params) = query(sql, params).column_values(0)

    def exec(sql, *params) = query(sql, params).cmd_tuples

    def transaction
      @raw.transaction { yield self }
    end

    # 互いに依存しない読み取りを 1 往復で送る（libpq の pipeline mode）。queries は [sql, params] の配列。
    def pipeline(queries)
      results = []
      @raw.enter_pipeline_mode
      begin
        queries.each { |sql, params| @raw.send_query_params(sql, params.map { |param| encode(param) }) }
        @raw.pipeline_sync
        loop do
          result = @raw.get_result
          next if result.nil?
          break if result.result_status == PG::PGRES_PIPELINE_SYNC

          results << result
        end
      ensure
        @raw.exit_pipeline_mode
      end
      results.each(&:check)
    end

    def close
      @raw.close
    rescue PG::Error
      nil
    end

    private

    # 全 SQL を prepare しないのは、接続 × SQL ごとの初回 prepare が europe/america で 1 往復（約 100ms）かかるため。
    # PREPARED に登録したものだけは接続時（起動時の prewarm）に prepare 済み。
    def query(sql, params)
      encoded = params.map { |param| encode(param) }
      name = PREPARED[sql]
      name ? @raw.exec_prepared(name, encoded) : @raw.exec_params(sql, encoded)
    end

    def encode(value)
      case value
      when nil then nil
      when String then value.encoding == Encoding::BINARY ? { value:, format: 1 } : value
      when Time then value.getutc.strftime('%Y-%m-%d %H:%M:%S.%6N+00')
      when Date then value.iso8601
      when Array then ARRAY_ENCODER.encode(value)
      when Hash then value
      else value.to_s
      end
    end
  end
end
