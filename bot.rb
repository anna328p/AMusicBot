#!/usr/bin/env ruby

Bundler.require :default
require './lib/patches'
require './lib/tio'

token = ENV['TOKEN']
raise 'No token in environment; set TOKEN' unless token

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

def log_command(name, event, args, extra = nil)
  user = event.author.id
  command = name.to_s
  arguments = args.join ' '

  string = "command execution by user #{user}: .#{command} #{arguments}"
  if extra
    string << "; #{extra}"
  end
  Log4r::Logger['bot'].info string
end

bot = Discordrb::Commands::CommandBot.new(
  token: token,
  prefix: '~',
  command_doesnt_exist_message: 'Invalid command.'
)

bot.command :echo, {
  help_available: true,
  description: 'Echoes a string',
  usage: '~echo <string>',
  min_args: 1
} do |event, *args|
  log_command(:echo, event, args)
  args.map { |a| a.gsub('@', "\\@\u200D") }.join(' ')
end

bot.command :eval, {
  help_available: false,
  description: 'Evaluates some code. Owner-only.',
  usage: '~eval <code>',
  min_args: 1
} do |e, *args|
  m = e.message
  a = e.author
  log_command(:eval, e, args)
  if a.id == 165998239273844736
    eval args.join(' ')
  else
    "nope"
  end
end

bot.command :tio, {
  help_available: true,
  description: 'Evaluates code using Try It Online',
  usage: '~tio <lang> [flags] ```<code>``` [```input```] [arguments]',
  min_args: 2
} do |event, *args|
  doc = Kramdown::Document.new(event.message.text, input: 'GFM')

  rc = doc.root.children
  #pp rc

  def walk_tree t
    if t.class == Array
      a = []
      t.each do |elem|
        if elem.children
          a << walk_tree(elem.children)
        else
          a << elem.dup
        end
      end
      return a
    else
      if t.children
        return walk_tree(t.children)
      else
        return elem.dup
      end
    end
  end

  pp walk_tree(rc)

  return

  t = event.message.text[3..-4].chomp
  lang = t.lines[0].chomp
  code = t.lines[1..-1].join('\n').chomp

  msg = nil

  if lang == 'ruby' && event.author.id == 165998239273844736
    e = event
    m = e.message
    a = e.author
    text = "```#{eval code}```"
    msg = event.respond text
  else
    res = TIO.run(lang, code)[0].gsub("```", "\\```").gsub('@', "\\@\u200D")
    msg = event.respond "```\n#{res}\n```"
  end

  msg.create_reaction('❌')
end


bot.reaction_add(emoji: '❌') do |event|
  if event.user.id != 680170235109703696
    event.message.delete
  end
end


bot.run true

while buf = Readline.readline('% ', true)
  s = buf.chomp
  if s.start_with? 'quit', 'stop'
    bot.stop
    exit
  elsif s.start_with? 'restart'
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
