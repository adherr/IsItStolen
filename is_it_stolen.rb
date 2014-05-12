#!/usr/bin/ruby

require 'twitter'

require 'config.rb'
# this is a file that contains the following config hash with the values filled in from your twitter account
#
# config = {
#   :consumer_key    => ""
#   :consumer_secret => "",
#   :access_token        => "",
#   :access_token_secret => "",
# }

client = Twitter::REST::Client.new(config)

def collect_with_max_id(collection=[], max_id=nil, &block)
  response = yield(max_id)
  collection += response
  response.empty? ? collection.flatten : collect_with_max_id(collection, response.last.id - 1, &block)
end

def client.get_all_tweets_at_me()
  collect_with_max_id() do |max_id|
    options = {:count => 200}
    options[:max_id] = max_id unless max_id.nil?
    mentions_timeline(options)
  end
end

at_me = client.get_all_tweets_at_me()

at_me.each do |tweet|
  puts tweet.full_text
end
