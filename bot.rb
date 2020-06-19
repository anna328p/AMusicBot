#!/usr/bin/env ruby

Bundler.require :default
require './lib/patches'
require 'yaml'
require 'digest'

$config = YAML.load File.read 'config.yml' || {}

token = $config['token']
raise 'No token in configuration; set token' unless token

client_id = $config['client-id']
raise 'No client id in configuration; set client-id' unless client_id


applog = Log4r::Logger.new 'bot'
applog.outputters = Log4r::Outputter.stderr
ActiveRecord::Base.logger = applog

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: 'db/database.sqlite3'
)

def define_schema
  ActiveRecord::Schema.define do
  end
end

bot = Discordrb::Commands::CommandBot.new(
  token: token,
  client_id: client_id,
  name: 'QueryBot',
  prefix: -> (m) {
    pfx = $config['servers'][m.channel.server.id]['prefix'] || '~'
    m.text.start_with?(pfx) ? m.text[pfx.length..-1] : nil
  },
  fancy_log: true,
  ignore_bots: true,
  no_permission_message: 'You are not allowed to do that',
  command_doesnt_exist_message: 'Invalid command.'
)

$queues = {}

def log_command(bot, name, event, args, extra = nil)
  user = event.author
  username = "#{user.name}##{user.discriminator}"
  command = name.to_s
  arguments = args.join ' '
  lc = $config['servers'][event.server.id]['log-channel']
  puts lc

  string = "command execution by #{username}: ~#{command} #{arguments}"
  if extra
    string << "; #{extra}"
  end
  Log4r::Logger['bot'].info string

  if lc
    log_channel = bot.channel(lc)
    log_channel.send_embed do |m|
      m.author = Discordrb::Webhooks::EmbedAuthor.new(
        name: username,
        icon_url: user.avatar_url
      )
      m.title = 'Command execution'
      m.fields = [
        Discordrb::Webhooks::EmbedField.new(
          name: "Command",
          value: "#{command} #{arguments}"
        ),
        Discordrb::Webhooks::EmbedField.new(
          name: "User ID",
          value: user.id,
          inline: true
        )
      ]
      if extra
        m.fields += Discordrb::Webhooks::EmbedField.new(
          name: "Information",
          value: extra
        )
      end
      m.timestamp = Time.now
    end
  end
end

bot.command :echo, {
  help_available: true,
  description: 'Echoes a string',
  usage: '~echo <string>',
  min_args: 1
} do |event, *args|
  log_command(bot, :echo, event, args)
  args.map { |a| a.gsub('@', "\\@\u200D") }.join(' ')
end

bot.command :eval, {
  help_available: false,
  description: 'Evaluates some code. Owner-only.',
  usage: '~eval <code>',
  min_args: 1
} do |e, *args|
  log_command(bot, :eval, e, args)

  m = e.message
  a = e.author
  if a.id == config['owner']
    eval args.join(' ')
  else
    "nope"
  end
end

bot.command :join, {
  help_available: true,
  description: 'Joins the voice channel',
  usage: '~join',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :join, event, [])

  vc = event.author.voice_channel
  if vc
    bot.voice_connect(vc)
    "Successfully joined the channel **#{vc.name}**!"
  else
    'You are not in a voice channel!'
  end
end

bot.command :play, {
  help_available: true,
  description: 'Plays music from a URL',
  usage: '~play <url>',
  min_args: 1
} do |event, *args|
  log_command(bot, :play, event, args)

  if !bot.voice(event.server)
    bot.execute_command(:join, event, [])
  end

  url = args.join(' ')
  filename = "/tmp/amb-#{Digest::SHA256.hexdigest url}.opus"

  event.respond "Downloading..."
  info = YoutubeDL.download url, output: filename, extract_audio: true, audio_format: :opus
  event.respond "Added **#{info.fulltitle || info.url}** to the queue."
  $queues[event.server.id] << [filename, info]

  nil
end

bot.command :pause, {
  help_available: true,
  description: 'Pauses the audio',
  usage: '~pause',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :pause, event, [])

  bot.voice(event.server).pause
end

bot.command :resume, {
  help_available: true,
  description: 'Resumes paused audio',
  usage: '~pause',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :resume, event, [])

  bot.voice(event.server).continue
end

bot.command :stop, {
  help_available: true,
  description: 'Stops playback',
  usage: '~pause',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :stop, event, [])

  $queues[event.server.id].clear
  bot.voice(event.server).stop_playing
end

bot.command :skip, {
  help_available: true,
  description: 'Skips the current track',
  usage: '~skip',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :skip, event, [])

  bot.voice(event.server).stop_playing
  bot.execute_command(:np, event, [])
end

bot.command :volume, {
  help_available: true,
  description: 'Sets the bot volume for this server',
  usage: '~volume <percentage>',
  min_args: 1,
  max_args: 1
} do |event, vol_str|
  log_command(bot, :volume, event, [vol_str])

  vol = vol_str.to_i / 100.0
  
  if vol <= 1
    vol *= 100
  end

  bot.voice(event.server).volume = vol
end

bot.command :seek, {
  help_available: true,
  description: 'Skips forward a few seconds',
  usage: '~seek <time>',
  min_args: 1,
  max_args: 1
} do |event, sec_str|
  log_command(bot, :play, event, [sec_str])

  sec = sec_str.to_i
  bot.voice(event.server).skip(sec)
end

$np = {}
bot.command :np, {
  help_available: true,
  description: 'Now playing',
  usage: '~np',
  min_args: 0,
  max_args: 0
} do |event|
  log_command(bot, :np, event, [])

  event.channel.send_embed do |m|
    m.title = 'Now playing'
    m.description = $np[event.server.id] || "Nothing"
  end

  nil
end

bot.run true

bot.servers.each do |id, server|
  $queues[server.id] = Queue.new
end

threads = {}
$queues.each do |id, q|
  threads[q] = Thread.new { 
    v = nil
    loop do
      until v
        v = bot.voice(id)
        sleep 1
      end
      while (fn, info = q.pop)
        $np[id] = info.fulltitle || info.url
        v.play_file(fn)
        $np[id] = nil
        if q.empty?
          v.destroy
          v = nil
          break
        end
      end
    end
  }
end

while buf = Readline.readline('% ', true)
  s = buf.chomp
  if s.start_with? 'quit', 'stop'
    bot.stop
    exit
  elsif s.start_with? 'r'
    bot.stop
    exec 'ruby', $PROGRAM_NAME
  elsif s.start_with? 'irb'
    binding.irb
  elsif s == ''
    next
  else
    puts 'Command not found'
  end
end

bot.join
