# frozen_string_literal: true

require 'openssl'

module Isureal
  module ImageSignature
    IMAGE_URL_LIFETIME = 24 * 60 * 60
    IMAGE_SIGNATURE_ITERATIONS = 1000

    module_function

    def signing_key(secret_key_hash)
      raise ArgumentError, 'invalid image signing key' unless secret_key_hash.is_a?(String) && secret_key_hash.match?(/\A\h{64}\z/)

      [secret_key_hash].pack('H*')
    end

    # ponytail: 上限到達で全消去する素朴なメモ。ヒット率が問題になれば LRU にする。
    SIGNATURE_MEMO = {}
    SIGNATURE_MEMO_LIMIT = 50_000

    def signature(key, image_id, exp)
      memo_key = [key, image_id, exp]
      if (memoized = SIGNATURE_MEMO[memo_key])
        return memoized
      end

      SIGNATURE_MEMO.clear if SIGNATURE_MEMO.size >= SIGNATURE_MEMO_LIMIT
      SIGNATURE_MEMO[memo_key] = compute_signature(key, image_id, exp).freeze
    end

    def compute_signature(key, image_id, exp)
      value = "#{exp}:#{image_id}".b
      mac = OpenSSL::HMAC.new(key, 'SHA256')
      IMAGE_SIGNATURE_ITERATIONS.times { value = mac.reset.update(value).digest }
      value
    end

    def encode(signature)
      [signature].pack('m0').tr('+/', '-_').delete('=')
    end

    def decode(text)
      return nil unless text.match?(/\A[A-Za-z0-9_-]*\z/) && (text.length % 4) != 1

      decoded = (text.tr('-_', '+/') + ('=' * (-text.length % 4))).unpack1('m0')
      encode(decoded) == text ? decoded : nil
    rescue ArgumentError
      nil
    end

    # 期限を分単位に切り捨てるのは、同じ画像の URL を 1 分間同じにして署名（HMAC 1000 回）のメモを効かせるため。
    EXP_GRANULARITY = 60

    # 呼び出し元はどれも、その時点で有効な画像を持ち主の user で署名するので、有効な状態として入れておける。
    # media_type を固定にするのは、作成時は常に image/jpeg で、初期データも全件 image/jpeg のため。
    def signed_url(user, image_id)
      ImageStateCache.put(image_id, user.secret_key_hash, 'image/jpeg') if ImageStateCache::SEED_ON_SIGN
      exp = (Time.now.to_i / EXP_GRANULARITY * EXP_GRANULARITY) + IMAGE_URL_LIFETIME
      sig = encode(signature(user.image_key, image_id, exp))
      "/api/images/#{escape_path(image_id)}?exp=#{exp}&sig=#{sig}"
    end

    def escape_path(value)
      value.b.gsub(%r{[^A-Za-z0-9\-_.~$&+,;=:@]}) { |char| format('%%%02X', char.ord) }
    end
  end
end
