# frozen_string_literal: true

module Isureal
  Config = Struct.new(:region, :db_host, :db_port, :db_user, :db_password, :db_name, :log_level, keyword_init: true) do
    def self.from_env
      new(
        region: env_or_default('ISUREAL_REGION', 'asia'),
        db_host: env_or_default('ISUREAL_DB_HOST', '127.0.0.1'),
        db_port: env_or_default('ISUREAL_DB_PORT', '5432'),
        db_user: env_or_default('ISUREAL_DB_USER', 'isureal'),
        db_password: env_or_default('ISUREAL_DB_PASSWORD', 'isureal'),
        db_name: env_or_default('ISUREAL_DB_NAME', 'isureal'),
        # error にしないのは、isureal-guard が info のアクションログ（ログイン失敗等）で BAN するため。
        log_level: env_or_default('ISUREAL_LOG_LEVEL', 'info'),
      )
    end

    def self.env_or_default(key, default_value)
      value = ENV[key]
      value.nil? || value.empty? ? default_value : value
    end

    def database_options
      # TLS を使わないのは、ハンドシェイクで新規接続ごとに europe/america で約 300ms 増えるため（通信は VPC 内）。
      # keepalives は、起動時に張ったまま使われない接続を経路上で切られないようにするため。
      { host: db_host, port: db_port, user: db_user, password: db_password, dbname: db_name,
        sslmode: 'disable', keepalives: 1, keepalives_idle: 30, keepalives_interval: 10, keepalives_count: 3 }
    end
  end
end
