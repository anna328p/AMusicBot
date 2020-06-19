#!/usr/bin/env ruby

Bundler.require :default
require './lib/patches'
require 'json'
require 'yaml'
require 'digest'
require 'uri'


# Load the initial configuration

$config = YAML.load File.read 'config.yml' || {}

token = $config['token']
raise 'No token in configuration; set token' unless token

client_id = $config['client-id']
raise 'No client id in configuration; set client-id' unless client_id


# Application logging

applog = Log4r::Logger.new 'bot'
applog.outputters = Log4r::Outputter.stderr
ActiveRecord::Base.logger = applog


# Bot database

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: 'db/database.sqlite3'
)

def define_schema
  ActiveRecord::Schema.define do
  end
end


# Initialize the YouTube Search API


REDIRECT_URI = 'http://localhost'
APPLICATION_NAME = 'AMusicBot'
CLIENT_SECRETS_PATH = 'yt-client-secret.json'
CREDENTIALS_PATH = 'yt-credentials.yml'
SCOPE = Google::Apis::YoutubeV3::AUTH_YOUTUBE_READONLY

def authorize
  client_id = Google::Auth::ClientId.from_file(CLIENT_SECRETS_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: CREDENTIALS_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(
    client_id, SCOPE, token_store)
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)
  if credentials.nil?
    url = authorizer.get_authorization_url(base_url: REDIRECT_URI)
    puts "Open the following URL in the browser and enter the " +
         "resulting code after authorization"
    puts url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: REDIRECT_URI)
  end
  credentials
end

$ytservice = Google::Apis::YoutubeV3::YouTubeService.new
$ytservice.client_options.application_name = APPLICATION_NAME
$ytservice.authorization = authorize

def youtube_search(query)
  results = $ytservice.list_searches(['snippet'], q: query)
  results.items
end

def results_getid(results)
  results[0].id.video_id
end


# Initialize bot

bot = Discordrb::Commands::CommandBot.new(
  token: token,
  client_id: client_id,
  name: 'AMusicBot',
  prefix: -> (m) {
    pfx = $config['servers'][m.channel.server.id]['prefix'] || '~'
    m.text.start_with?(pfx) ? m.text[pfx.length..-1] : nil
  },
  fancy_log: true,
  ignore_bots: true,
  no_permission_message: 'You are not allowed to do that',
  command_doesnt_exist_message: 'Invalid command.'
)

# Play queues
$queues = {}

# Listen for a user response
def user_response(bot, event)
  event = bot.add_await!(Discordrb::Events::MentionEvent, in: event.channel, from: event.author)
  event.message.text.split[1].to_i
end


# This function is used by every command for logging purposes

def log_command(bot, name, event, args, extra = nil)
  user = event.author
  username = "#{user.name}##{user.discriminator}"
  command = name.to_s
  arguments = args.join ' '
  lc = $config['servers'][event.server.id]['log-channel']
  puts lc

  # Log to stdout
  string = "command execution by #{username}: ~#{command} #{arguments}"
  if extra
    string << "; #{extra}"
  end
  Log4r::Logger['bot'].info string

  # Log to channel using an embed
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


# General commands

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


# Voice functionality

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

  # Join the channel if not joined already
  if !bot.voice(event.server)
    bot.execute_command(:join, event, [])
  end

  # Temporary file for the track based on a hash of its URL
  url = args.join(' ')
  if !(url =~ URI::regexp)
    url = "ytsearch:#{url}"
  end
  filename = "/tmp/amb-#{Digest::SHA256.hexdigest url}.opus"

  info = nil
  # Download the track; get info
  if File.exist?(filename) && File.exist?(filename + '.dat')
    info = Marshal.load(File.read(filename + '.dat'))
  else
    event.respond "Downloading..."
    info = YoutubeDL.download url, output: filename, extract_audio: true, audio_format: :opus
    File.write(filename + '.dat', Marshal.dump(info))
  end


  # Add it to this server's queue
  event.respond "Added **#{info.fulltitle || info.url}** to the queue."
  $queues[event.server.id] << [filename, info]

  nil
end

def to_word(num)
  numbers = [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ]
  words = %w( zero one two three four five six seven eight nine ten )
  map = numbers.zip(words).to_h
  map[num] || num
end

bot.command :yt, {
  help_available: true,
  description: 'Searches YouTube for a video to play',
  usage: '~yt <query>',
  min_args: 1
} do |event, *args|
  log_command(bot, :yt, event, args)

  # Get the search query
  query = args.join(' ')

  # Search YouTube
  results = youtube_search(query)
  
  # Show the search results in the channel
  event.channel.send_embed do |m|
    m.title = "Search results for #{query}"
    m.description = "To choose a result, ping the bot with its number."
    m.fields = results.map.with_index { |r, idx|
      Discordrb::Webhooks::EmbedField.new(
        name: ":#{to_word(idx + 1)}:  #{r.snippet.title}",
        value: "#{d = r.snippet.description; d.size < 192 ? d : d[0..191].chomp + '...'}\nhttps://youtu.be/#{r.id.video_id}"
      )
    }
  end

  # Get the user's response
  number = user_response(bot, event)
  ytid = results[number - 1].id.video_id

  # Actually play the found video
  bot.execute_command(:play, event, [ytid])
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

  vol = vol_str.to_f

  # Allow for both 0-1 and percentages
  if vol > 1
    vol /= 100.0
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


# Post-init

bot.listening = '~help for help'

# Create a queue for each server
bot.servers.each do |id, server|
  $queues[server.id] = Queue.new
end


# Play music on every server

threads = {}
$queues.each do |id, q|
  # For every queue, make a thread that plays the music in the queue.
  threads[q] = Thread.new {
    v = nil
    loop do
      # Wait for the voicebot to initialize
      until v
        v = bot.voice(id)
        sleep 1
      end

      while (fn, info = q.pop)
        # Play the next queued track
        $np[id] = info.fulltitle || info.url
        v.play_file(fn)
        $np[id] = nil

        # If there is no more music, disconnect and clear the voicebot
        if q.empty?
          v.destroy
          v = nil
          break
        end
      end
    end
  }
end


# Bot CLI

while buf = Readline.readline('% ', true)
  s = buf.chomp
  if s.start_with? 'quit', 'stop'
    # Stop the bot and exit
    bot.stop
    exit
  elsif s.start_with? 'restart' || s == 'rs'
    # Restart the bot
    bot.stop
    exec 'ruby', $PROGRAM_NAME
  elsif s.start_with? 'reload'
    # Reload the bot's config
    $config = YAML.load File.read 'config.yml' || {}
  elsif s.start_with? 'irb'
    # Open a REPL in the context of the bot
    binding.irb
  elsif s == ''
    next
  else
    puts 'Command not found'
  end
end

bot.join
