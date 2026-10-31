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
  end

  class Connection
    ARRAY_ENCODER = PG::TextEncoder::Array.new
    TYPE_REGISTRY = PG::BasicTypeRegistry.new.register_default_types
                                         .register_type(0, 'numeric', PG::TextEncoder::Float, PG::TextDecoder::Float)

    def initialize(raw)
      @raw = raw
      @raw.type_map_for_results = PG::BasicTypeMapForResults.new(@raw, registry: TYPE_REGISTRY)
      @raw.field_name_type = :symbol
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

    def close
      @raw.close
    rescue PG::Error
      nil
    end

    private

    # prepare しないのは、接続 × SQL ごとの初回 prepare が europe/america で 1 往復（約 100ms）かかるため。
    def query(sql, params)
      @raw.exec_params(sql, params.map { |param| encode(param) })
    end

    def encode(value)
      case value
      when nil then nil
      when String then value.encoding == Encoding::BINARY ? { value:, format: 1 } : value
      when Time then value.getutc.strftime('%Y-%m-%d %H:%M:%S.%6N+00')
      when Date then value.iso8601
      when Array then ARRAY_ENCODER.encode(value)
      else value.to_s
      end
    end
  end
end
