# frozen_string_literal: true

require 'fileutils'
require 'net/http'
require 'openssl'
require 'socket'

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

    # nginx が X-Accel-Redirect で返すときの内部 URI の接頭辞（etc/nginx/sites-available/isureal.conf の location と対応）。
    NGINX_PREFIXES = { INITIAL_DIR => '/_image_files/initial/', DIR => '/_image_files/runtime/' }.freeze

    def nginx_uri(id)
      return nil unless CACHEABLE_ID.match?(id)

      dir = [INITIAL_DIR, DIR].find { |candidate| File.exist?(File.join(candidate, id)) }
      dir && "#{NGINX_PREFIXES[dir]}#{id}"
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

  # 画像の本体は nginx がディスクから返す。asia2 は nginx を持たず asia1 の nginx 経由で応答し、
  # asia1 のディスクに無い画像を指してしまうので、自ホストに nginx の設定があるときだけ使う。
  NGINX_SENDS_IMAGES = File.exist?('/etc/nginx/conf.d/isureal-upstream.conf')

  # 作成した画像の本体は DB に入れず作成したサーバーのディスクに置き、他のサーバーは必要時に取り寄せる。
  module ImageOrigin
    SELF = ENV.fetch('ISUREAL_IMAGE_ORIGIN') { "#{Socket.ip_address_list.find(&:ipv4_private?)&.ip_address}:8080" }

    module_function

    def fetch(origin, id)
      return nil unless ImageCache::CACHEABLE_ID.match?(id)
      return ImageCache.read(id) if origin == SELF

      host, port = origin.split(':')
      connections = (Thread.current[:isureal_origin_http] ||= {})
      # 1 回だけやり直すのは、相手が閉じた keep-alive 接続を使って失敗することがあるため。
      2.times do
        http = connections[origin] ||= Net::HTTP.start(host, Integer(port), open_timeout: 3, read_timeout: 10)
        response = http.get("/internal/images/#{id}")
        return response.code == '200' ? response.body.b : nil
      rescue IOError, SystemCallError, Timeout::Error
        begin
          connections.delete(origin)&.finish
        rescue IOError
          nil
        end
      end
      nil
    end
  end

  # 削除から 5 秒以内は画像を返してよいので、有効と確認した状態を TTL の間だけ DB に問い合わせずに使う。
  # Puma のワーカー間で共有するため、プロセスのメモリではなく tmpfs のファイルに置く。
  module ImageStateCache
    TTL = 3.0
    DIR = ENV.fetch('ISUREAL_IMAGE_STATE_DIR', '/dev/shm/isureal-image-state')
    # 状態確認が他リージョンの DB への往復になる europe/america だけ、URL を作った時点で状態を入れておく。
    SEED_ON_SIGN = %w[europe america].include?(ENV.fetch('ISUREAL_REGION', 'asia'))

    module_function

    def get(id)
      return nil unless ImageCache::CACHEABLE_ID.match?(id)

      expires_at, secret_key_hash, media_type = File.read(File.join(DIR, id)).split("\t")
      { secret_key_hash:, media_type:, valid: true } if expires_at.to_f > now
    rescue Errno::ENOENT
      nil
    end

    def put(id, secret_key_hash, media_type)
      return unless ImageCache::CACHEABLE_ID.match?(id)

      path = File.join(DIR, id)
      tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(tmp, "#{now + TTL}\t#{secret_key_hash}\t#{media_type}")
      File.rename(tmp, path)
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  FileUtils.mkdir_p(ImageStateCache::DIR)

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
      FROM image_meta i JOIN users u ON u.id = i.owner_user_id AND u.status = 'active'
      WHERE i.id = $1
    SQL
    IMAGE_STATE_ONLY_SQL = format(IMAGE_STATE_SQL, '').freeze
    # 本体は created_at も指定して image_objects のパーティションを 1 つに絞る。JOIN や LATERAL にしないのは、
    # 実行時の絞り込みが効かず、該当するまで古いパーティションから順に引くため。
    IMAGE_OBJECT_SQL = 'SELECT d.%s FROM image_objects d WHERE d.id = i.id AND d.created_at = i.created_at'
    IMAGE_STATE_WITH_DATA_SQL = format(IMAGE_STATE_SQL, ", (#{format(IMAGE_OBJECT_SQL, 'data')}) AS data, (#{format(IMAGE_OBJECT_SQL, 'origin')}) AS origin").freeze
    Connection.prepare_on_connect(IMAGE_STATE_ONLY_SQL, IMAGE_STATE_WITH_DATA_SQL)

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

      nginx_uri = NGINX_SENDS_IMAGES && ImageCache.nginx_uri(input[:image_id])
      cached = nginx_uri || ImageCache.read(input[:image_id])
      state = cached && ImageStateCache.get(input[:image_id])
      row = state || db.get(cached ? IMAGE_STATE_ONLY_SQL : IMAGE_STATE_WITH_DATA_SQL, input[:image_id])
      raise APIError.new(403, 'image_forbidden') if row.nil? || (row.key?(:data) && row[:data].nil?)

      key = ImageSignature.signing_key(row[:secret_key_hash])
      unless OpenSSL.fixed_length_secure_compare(sig, ImageSignature.signature(key, input[:image_id], exp))
        env['isureal.abuse'] = 'invalid_signature'
        raise APIError.new(403, 'image_forbidden')
      end
      raise APIError.new(403, 'image_forbidden') unless row[:valid]
      raise APIError.new(403, 'image_forbidden') if exp <= Time.now.to_i

      if nginx_uri
        ImageStateCache.put(input[:image_id], row[:secret_key_hash], row[:media_type]) unless state
        headers['x-accel-redirect'] = nginx_uri
        return blob(200, row[:media_type], '')
      end

      data = cached || (row[:data].empty? ? row[:origin] && ImageOrigin.fetch(row[:origin], input[:image_id]) : row[:data])
      raise "image #{input[:image_id]} is not available from #{row[:origin].inspect}" if data.nil?

      ImageCache.write(input[:image_id], data) unless cached
      ImageStateCache.put(input[:image_id], row[:secret_key_hash], row[:media_type]) unless state
      blob(200, row[:media_type], data)
    end

    # 他のサーバーが画像本体を取り寄せるための内部 API。nginx は /api/ しか転送しないので外部からは 8080 に直接来るしかなく、
    # 接続元がプライベートアドレスであることで制限する（X-Client-IP は偽装できるので見ない）。
    def internal_image_handler
      remote = Addrinfo.ip(env['REMOTE_ADDR'].to_s)
      raise APIError.new(403, 'forbidden') unless remote.ipv4_private? || remote.ipv4_loopback?

      data = ImageCache.read(params['imageId'])
      raise APIError.new(404, 'image_not_found') if data.nil?

      blob(200, 'application/octet-stream', data)
    rescue SocketError
      raise APIError.new(403, 'forbidden')
    end
  end
end
