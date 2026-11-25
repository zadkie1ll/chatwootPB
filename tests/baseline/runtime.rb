# Diagnostic checks only; does not change schema or application configuration.
require 'json'
require 'sidekiq/api'

Rails.application.eager_load!
checks = {
  source_commit: Rails.root.join('.git_sha').read.strip == 'b2f94636d325a126a67c6c4c808303d8aa8cbeea',
  enterprise_directory_absent: !Rails.root.join('enterprise').exist?,
  enterprise_disabled: !ChatwootApp.enterprise?,
  enterprise_extensions_absent: ChatwootApp.extensions.empty?,
  database_name: ActiveRecord::Base.connection_db_config.database == 'chatwoot_lab',
  database_role_not_superuser: !ActiveRecord::Base.connection.select_value('SELECT rolsuper FROM pg_roles WHERE rolname = current_user'),
  redis_responds: Redis::Alfred.with { |connection| connection.ping } == 'PONG',
  sidekiq_heartbeat: Sidekiq::ProcessSet.new.any?,
  active_storage_local: Rails.application.config.active_storage.service == :local,
  migrations_current: !ActiveRecord::Base.connection_pool.migration_context.needs_migration?
}
puts JSON.generate({ kind: 'stage-1-runtime', checks: checks, all_passed: checks.values.all? })
raise 'Runtime checks failed' unless checks.values.all?
