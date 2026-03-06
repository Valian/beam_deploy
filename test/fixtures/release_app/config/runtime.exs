import Config

if config_env() == :prod do
  config :beam_deploy, enabled: true
end
