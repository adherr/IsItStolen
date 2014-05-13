#!/usr/bin/ruby

require 'dotenv'
require 'tweetstream'
require 'faraday'
require 'json'

Dotenv.load

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


def make_bike_desc(max_char, bike={})
  color = bike["frame_colors"][0].downcase!
  if color.start_with?("silver")
    color.replace "gray"
  elsif color.start_with?("stickers")
    color.replace ''
  end

  manufacturer = bike["manufacturer_name"]
  model = bike["frame_model"]

  full_length = color.length+model.length+manufacturer.length+2
  if full_length <= max_char
    return "#{color} #{manufacturer} #{model}"
  elsif full_length - color.length - 1 <= max_char
    return "#{manufacturer} #{model}"
  elsif full_length - manufacturer.length - 1 <= max_char
    return "#{color} #{model}"
  elsif full_length - model.length - 1 <= max_char
    return "#{color} #{manufacturer}"
  elsif model.length + 2 <= max_char
    return "a #{model}"
  elsif manufacturer.length + 2 <= max_char
    return "a #{manufacturer}"
  elsif color.length + 5 <= max_char
    return "#{color} bike"
  else
    return ""
  end
end



stream_client.userstream do |tweet|

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

  # go search the bike index
  bike_index_response = Faraday.get 'https://bikeindex.org/api/v1/bikes', { :serial => search_term }
  # bikes is an array of bike hashes from the bike index
  bikes = JSON.parse(bike_index_response.body)["bikes"]

  # stuff to use in the twitter status reply
  update_opts = { :in_reply_to_status => tweet}
  at_user_strin = "@#{tweet.user.screen_name}" #This is 16 characters max ('@' + 15 for screen name)

  # There are several cases of outcomes here
  # 1. no bikes found
  if bikes.empty?
    reply = "Sorry #{at_user_strin}, I couldn't find that bike on the Bike Index https://BikeIndex.org"
    
    # 2. only one bike found
  elsif bikes.length == 1

    # 2a. The bike we found is an exact match of the search term
    if bikes[0]["serial"] == search_term
      #2a1. stolen
      if bikes[0]["stolen"]
        reply = "#{at_user_strin} Found " + make_bike_desc(86, bikes[0]) + " listed as STOLEN #{bikes[0]["url"]}"
      else
        #reply = "#{at_user_strin} Found " + make_bike_desc(82, bikes[0]) + " listed as NOT stolen #{bikes[0]["url"]}"
      end
    end

    # send the tweet
    rest_client.update(reply, update_opts)
    puts reply
  end
end
