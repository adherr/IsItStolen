#!/usr/bin/ruby

require 'rubygems'
require 'bundler/setup' 

require 'dotenv'
require 'tweetstream'
require 'faraday'
require 'json'

Dotenv.load

# set up the clients
TweetStream.configure do |config|
  config.consumer_key    = ENV['consumer_key']
  config.consumer_secret = ENV['consumer_secret']
  config.oauth_token        = ENV['access_token']
  config.oauth_token_secret = ENV['access_token_secret']
  config.auth_method        = :oauth
end

stream_client = TweetStream::Client.new

rest_client = Twitter::REST::Client.new do |config|
  config.consumer_key    = ENV['consumer_key']
  config.consumer_secret = ENV['consumer_secret']
  config.access_token        = ENV['access_token']
  config.access_token_secret = ENV['access_token_secret']
end

# grab the current t.co wrapper length for https links
HTTPS_LENGTH = rest_client.configuration.short_url_length_https
TWEET_LENGTH = 140

# whoami? (remember this so we can not respond to our own messages in the stream)
i_am_user = rest_client.verify_credentials


# @param at_screen_name [String] screen_name to reply to with @ already prepended (ready to send)
# @param bike [Hash] bike hash as delivered by BikeIndex that we're going to tweet about
def build_bike_reply(at_screen_name, bike={})
  max_char = TWEET_LENGTH - HTTPS_LENGTH - at_screen_name.length - 3 # spaces between slugs
  stolen_slug = bike["stolen"] ? "STOLEN" : "NOT stolen"

  max_char -= stolen_slug.length

  color = bike["frame_colors"][0]
  if color.start_with?("Silver")
    color.replace "Gray"
  elsif color.start_with?("Stickers")
    color.replace ''
  end

  manufacturer = bike["manufacturer_name"]
  model = bike["frame_model"]

  full_length = color.length+model.length+manufacturer.length+2
  if full_length <= max_char
    bike_slug = "#{color} #{manufacturer} #{model}"
  elsif full_length - color.length - 1 <= max_char
    bike_slug = "#{manufacturer} #{model}"
  elsif full_length - manufacturer.length - 1 <= max_char
    bike_slug = "#{color} #{model}"
  elsif full_length - model.length - 1 <= max_char
    bike_slug = "#{color} #{manufacturer}"
  elsif model.length + 2 <= max_char
    bike_slug = "a #{model}"
  elsif manufacturer.length + 2 <= max_char
    bike_slug = "a #{manufacturer}"
  elsif color.length + 5 <= max_char
    bike_slug = "#{color} bike"
  else
    bike_slug = ""
  end

  return "#{at_screen_name} #{bike_slug} #{stolen_slug} #{bike["url"]}"
end



stream_client.userstream do |tweet|
  # don't respond to my outgoing tweets
  if tweet.user == i_am_user
    next
  end

  # remove user mentions from the incoming tweet
  search_term = tweet.full_text

  ### If the incoming tweet doesn't have our username at the beginning or end we should probably do something smarter than smashing the before and after parts together to make a search term, as this is unlikely to yield a serial number
  tweet.user_mentions.each do |user_mention|
    search_term = (user_mention.indices[0] > 0 ? search_term.slice(0..(user_mention.indices[0]-1)) : "") + search_term.slice(user_mention.indices[1]..-1)
  end
  # and what the hell, get hashtags too
  tweet.hashtags.each do |hashtag|
    search_term = (hashtag.indices[0] > 0 ? search_term.slice(0..(hashtag.indices[0]-1)) : "") + search_term.slice(hashtag.indices[1]..-1)
  end
  # remove whitespace from the ends for matching with returned serial later on
  search_term.strip!


  # stuff to use in the twitter status reply
  update_opts = { :in_reply_to_status => tweet}
  at_screen_name = "@#{tweet.user.screen_name}" #This is 16 characters max ('@' + 15 for screen name)


  # Don't bother to search if the serial number is "absent"
  if search_term.downcase == "absent"
    reply = "#{at_screen_name} There are way too many bikes without serial numbers for me to tweet. Search here: https://bikeindex.org/bikes?serial=ABSENT"
    rest_client.update(reply, update_opts)
    next
  end

  # go search the bike index
  bike_index_response = Faraday.get 'https://bikeindex.org/api/v1/bikes', { :serial => search_term }
  # make bikes an array of bike hashes from the bike index
  bikes = JSON.parse(bike_index_response.body)["bikes"]

  # There are several cases of outcomes here
  # 1. no bikes found
  if bikes.empty?
    reply = "Sorry #{at_screen_name}, I couldn't find that bike on the Bike Index https://BikeIndex.org"
    rest_client.update(reply, update_opts)

  # 2. a few bikes found
  elsif bikes.length >= 1 && bikes.length <= 3
    if bikes.length > 1
      reply = "#{at_screen_name} There are #{bikes.length} bikes with that serial number. I'll tweet them to you. https://BikeIndex.org/bikes?serial=#{search_term}"
     rest_client.update(reply, update_opts)
    end
    
    bikes.each do |bike|
      
      reply = build_bike_reply(at_screen_name, bike)
      rest_client.update(reply, update_opts)
#      puts reply
    end
  # 3. There are more than 3 bikes, just send to the search results
  else 
    reply = "Whoa, #{at_screen_name} there are #{bikes.length} bikes with that serial! Too many to tweet. Check here: https://BikeIndex.org/bikes?serial=#{search_term}"
  end
end
