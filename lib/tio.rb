require 'net/http'
require 'open-uri'
require 'json'
require 'nokogiri'
require 'zlib'

module TIO
  @@base = "https://tio.run"

  def self.run_endpoint
    @@run_endpoint ||= open(
      @@base + Nokogiri::HTML.parse(open(@@base)).xpath("//head/script[2]/@src")[0]
    ).readlines.grep(/^var runURL/)[0][14..-4]
  end

  def self.gzdeflate(s)
    Zlib::Deflate.new(nil, -Zlib::MAX_WBITS).deflate(s, Zlib::FINISH)
  end
  def self.gzinflate(s)
    Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(s)
  end

  def self.get_languages
    JSON.parse open("#{base}/languages.json").read
  end
  def self.get_languages_by_category(category)
    langs = get_languages
    return langs.filter { |k, v| v["categories"].include? category.to_s }
  end

  def self.file(name, body)
    "F#{name}\0#{body.size}\0#{body}"
  end

  def self.var(name, args)
    "V#{name}\0#{args.size}\0#{args.map { |a| "#{a}\0"}.join}"
  end

  def self.run(language, code, flags = nil, input = nil, arguments = nil)
    args = "/" # purpose unknown

    val = ""
    val += self.var('lang', [language])
    val += self.var('args', arguments)
    val += self.var("TIO_OPTIONS", flags) if flags && !(language.start_with? "java-")
    val += self.var("TIO_CFLAGS", flags) if flags
    val += self.file('.code.tio', code)
    val += self.file('.input.tio', input) if input
    val += "R"

    req_body = self.gzdeflate(val)

    request_count = 0
    begin
      token = Random.new.bytes(16).chars.map { |c| c.ord.to_s(16) }.join
      uri_string = @@base + run_endpoint + args + token

      uri = URI(uri_string)
      post_res = Net::HTTP.post(uri, req_body)
      request_count += 1
      post_res.value
    rescue Net::HTTPServerException
      if request_count < 5
        retry
      else
        raise
      end
    end

    res = gzinflate(post_res.body[10..-1])

    fields = res.split(res[0..15])[1..-1].map(&:chomp)
  end
end
