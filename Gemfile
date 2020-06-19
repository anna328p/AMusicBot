source 'https://rubygems.org'

group :default do
  # dirty hack to fix bundix problems
  gem 'discordrb-webhooks', git: 'https://github.com/dkudriavtsev/discordrb', branch: 'voice_websocket_update', ref: '43895b3ccc2bb12a38f43b3a720ba4aaf6eafe27'
  # fix websockets not connecting
  gem 'discordrb', git: 'https://github.com/swarley/discordrb', branch: 'voice_websocket_update'
  gem 'rbnacl'
  gem 'irb'

  gem 'readline'

  gem 'activerecord', require: 'active_record'
  gem 'sqlite3'

  gem 'dotenv', require: 'dotenv/load'

  gem 'youtube-dl.rb'

  gem 'log4r'
end
