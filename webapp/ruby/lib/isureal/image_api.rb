# frozen_string_literal: true

require 'fileutils'
require 'openssl'

module Isureal
  # image_objects の中身は不変で id も再利用されないため、初期化をまたいでも破棄不要。
  # 正は DB のままにし、削除状態も毎回 DB で確認する。
  # INITIAL_DIR は script/build_image_cache.rb で初期データから事前に作る。
  module ImageCache
    DIR = ENV.fetch('ISUREAL_IMAGE_CACHE_DIR', File.expand_path('~/local/image-cache'))
    INITIAL_DIR = ENV.fetch('ISUREAL_INITIAL_IMAGE_CACHE_DIR', File.expand_path('~/local/image-cache-initial'))
    CACHEABLE_ID = /\A[0-9A-Za-z-]{1,64}\z/

    module_function

    def read(id)
      return nil unless CACHEABLE_ID.match?(id)

      [INITIAL_DIR, DIR].each do |dir|
        return File.binread(File.join(dir, id))
      rescue Errno::ENOENT
        next
      end
      nil
    end

    def write(id, data)
      return unless CACHEABLE_ID.match?(id)

      path = File.join(DIR, id)
      tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.binwrite(tmp, data)
      File.rename(tmp, path)
    end
  end

  FileUtils.mkdir_p(ImageCache::DIR)

  class App
    GET_IMAGE_REQUEST = {
      image_id: { param: 'imageId' },
      exp: { query: 'exp' },
      sig: { query: 'sig' },
    }.freeze

    IMAGE_STATE_SQL = <<~SQL
      SELECT u.secret_key_hash, i.media_type, (
          u.profile_image_id = i.id
          OR EXISTS (
            SELECT 1 FROM posts p
            WHERE p.image_id = i.id AND p.author_id = u.id AND p.deleted_at IS NULL
          )
          OR EXISTS (
            SELECT 1 FROM realmojis r
            JOIN posts p ON p.id = r.post_id AND p.deleted_at IS NULL
            JOIN users author ON author.id = p.author_id AND author.status = 'active'
            WHERE r.image_id = i.id AND r.reactor_id = u.id AND r.replaced_at IS NULL AND r.deleted_at IS NULL
          )
        ) AS valid
        %s
      FROM image_objects i JOIN users u ON u.id = i.owner_user_id AND u.status = 'active'
      WHERE i.id = $1
    SQL
    IMAGE_STATE_ONLY_SQL = format(IMAGE_STATE_SQL, '').freeze
    IMAGE_STATE_WITH_DATA_SQL = format(IMAGE_STATE_SQL, ', i.data').freeze

    INT64_RANGE = (-(2**63)...(2**63))

    def parse_image_exp(value)
      return nil unless value.match?(/\A[+-]?\d+\z/)

      exp = value.to_i
      exp.to_s == value && INT64_RANGE.cover?(exp) ? exp : nil
    end

    def get_image_handler
      headers['cache-control'] = 'no-store'
      input = begin
        bind(GET_IMAGE_REQUEST)
      rescue HTTPError
        raise APIError.new(403, 'image_forbidden')
      end
      query, error = Bind.parse_query(request.query_string)
      if error || query.fetch('exp', []).length != 1 || query.fetch('sig', []).length != 1
        raise APIError.new(403, 'image_forbidden')
      end

      exp = parse_image_exp(input[:exp])
      raise APIError.new(403, 'image_forbidden') if exp.nil? || exp <= Time.now.to_i

      sig = ImageSignature.decode(input[:sig])
      raise APIError.new(403, 'image_forbidden') if sig.nil? || sig.bytesize != 32

      # 削除状態を毎回確認する。即時反映も5秒以内の許容範囲に含まれる。
      cached = ImageCache.read(input[:image_id])
      row = db.get(cached ? IMAGE_STATE_ONLY_SQL : IMAGE_STATE_WITH_DATA_SQL, input[:image_id])
      raise APIError.new(403, 'image_forbidden') if row.nil?

      key = ImageSignature.signing_key(row[:secret_key_hash])
      unless OpenSSL.fixed_length_secure_compare(sig, ImageSignature.signature(key, input[:image_id], exp))
        env['isureal.abuse'] = 'invalid_signature'
        raise APIError.new(403, 'image_forbidden')
      end
      raise APIError.new(403, 'image_forbidden') unless row[:valid]
      raise APIError.new(403, 'image_forbidden') if exp <= Time.now.to_i

      ImageCache.write(input[:image_id], row[:data]) unless cached
      blob(200, row[:media_type], cached || row[:data])
    end
  end
end
