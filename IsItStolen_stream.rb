#!/usr/bin/ruby

require 'rubygems'
require 'bundler/setup'

require 'open-uri'

require 'dotenv'
require 'tweetstream'
require 'twitter'
require 'faraday'
require 'json'
require 'geocoder'

class IsItStolen


  # Set up the streaming and REST API clients we'll use
  # BEWARE!: These methods could fail (and I should probably put them in a setup function after object creation)
  def initialize
    Dotenv.load
    @search_url = "https://BikeIndex.org/bikes?stolen=true&non_proximity=true"
    # set up the clients
    TweetStream.configure do |config|
      config.consumer_key    = ENV['CONSUMER_KEY']
      config.consumer_secret = ENV['CONSUMER_SECRET']
      config.oauth_token        = ENV['ACCESS_TOKEN']
      config.oauth_token_secret = ENV['ACCESS_TOKEN_SECRET']
      config.auth_method        = :oauth
    end

    @stream_client = TweetStream::Client.new

    @rest_client = Twitter::REST::Client.new do |config|
      config.consumer_key    = ENV['CONSUMER_KEY']
      config.consumer_secret = ENV['CONSUMER_SECRET']
      config.access_token        = ENV['ACCESS_TOKEN']
      config.access_token_secret = ENV['ACCESS_TOKEN_SECRET']
    end


    # a little status for the logs
    @stream_client.on_inited do
      puts 'Connected...'
    end
    @stream_client.on_error do |message|
      puts message
    end
    @stream_client.on_reconnect do |timeout, retries|
      puts "Reconnected: timeout #{timeout}, retries: #{retries}"
    end


    # grab the current t.co wrapper length for https links and other quantities
    @https_length = @rest_client.configuration.short_url_length_https
    @media_length = @rest_client.configuration.characters_reserved_per_media
    # define constants here
    @tweet_length = 140
    @stolen_str = "**STOLEN**"
    @not_stolen_str = "all's good"
    @respond_history_time = 3600 # how far to go back and respond to tweets on restart (in seconds)

    # whoami? (remember this so we can not respond to our own messages in the stream)
    @i_am_user = @rest_client.verify_credentials
    puts "I am #{@i_am_user.screen_name}" # if $DEBUG

  end

  # Perform the conditional text processing to create a reply string
  # that fits twitter's limits
  #
  # @param at_screen_name [String] screen_name to reply to with @ already prepended (ready to send)
  # @param bike [Hash] bike hash as delivered by BikeIndex that we're going to tweet about
  def build_bike_reply(at_screen_name, bike)
    max_char = @tweet_length - @https_length - at_screen_name.length - 3 # spaces between slugs
    stolen_slug = bike["stolen"] ? @stolen_str : @not_stolen_str

    max_char -= stolen_slug.length
    max_char -= bike["large_img"] ? @media_length : 0

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

  # sends a tweet with media and echos it, with error handling
  #
  # @param message [String] the text to send
  # @param media_location [String] URI of photo to send
  # @param options [Hash] same options as
  def send_tweet(message, media_location, options={})
    result = nil

    if media_location
      File.open('temp.jpg', 'wb') do |foto|
        foto.write open(media_location).read
      end
      File.open('temp.jpg', 'r') do |foto|
        result = @rest_client.update_with_media(message, foto, options)
      end
    else
      result = @rest_client.update(message, options)
    end

    puts "Sent \"#{result.full_text}\"" # if $DEBUG

    rescue Twitter::Error => e
      puts "recieved #{e.message}, no reply sent"
    # here we assume that non-Twitter errors are file errors
# we can't really be sure of this, and we don't want to end up sending doubles, so no
#    rescue
#      send_tweet(message, nil, options)
  end


  # Takes the full text of the incoming tweet and attempts to isolate
  # the serial number
  #
  # @param tweet [Twitter::Tweet] incoming tweet
  # @return [String] string to search the BikeIndex for
  def create_search_term(tweet)
    search_term = tweet.full_text

    # remove user mentions from the incoming tweet using the indices included in the Entity
    tweet.user_mentions.each do |user_mention|
      search_term = (user_mention.indices[0] > 0 ? search_term.slice(0..(user_mention.indices[0]-1)) : "") + search_term.slice(user_mention.indices[1]..-1)
    end

    # and what the hell, get hashtags too
    tweet.hashtags.each do |hashtag|
      search_term = (hashtag.indices[0] > 0 ? search_term.slice(0..(hashtag.indices[0]-1)) : "") + search_term.slice(hashtag.indices[1]..-1)
    end

    # remove whitespace from the ends for matching with returned serial later on
    search_term.strip!
  end

  # @param search_term [String] What to search the BikeIndex for
  # @param close_serials [Boolean] whether to search close serials or exact serials (default)
  # @return [Array] of bike hashes as defined bike the BikeIndex API https://bikeindex.org/documentation/api_v1
  def search_bike_index(search_term, close_serials = nil)
    url = close_serials ? 'https://bikeindex.org/api/v2/bikes_search/close_serials' : 'https://bikeindex.org/api/v2/bikes_search'
    bike_index_response = Faraday.get url, { :serial => search_term }

    JSON.parse(bike_index_response.body)["bikes"]
  end


  # Takes a tweet, picks it apart, queries BikeIndex, and replies to tweet
  #
  # @param tweet [Twitter::Tweet] an incoming tweet to process
  def process_tweet(tweet)

    puts "got tweet \"#{tweet.full_text}\"" # if $DEBUG

    # don't respond to my outgoing tweets
    if tweet.user == @i_am_user
      puts "my tweet... next!" # if $DEBUG
      return
    end
    # don't respond to retweets that mention me
    if tweet.retweet?
      puts "it's a retweet...skipping"
      return
    end

    search_term = create_search_term(tweet)
    puts "searching for \"#{search_term}\"" # if $DEBUG

    # stuff to use in the twitter status reply
    update_opts = { :in_reply_to_status => tweet}
    at_screen_name = "@#{tweet.user.screen_name}" #This is 16 characters max ('@' + 15 for screen name)

    # Don't bother to search if the serial number is "absent"
    if search_term.downcase == "absent"
      reply = "#{at_screen_name} There are way too many bikes without serial numbers for me to tweet. Search here: #{@search_url}&serial=ABSENT"
      send_tweet(reply, nil, update_opts)
      return
    end

    bikes = search_bike_index(search_term)
    puts "got #{bikes.length} bikes" # if $DEBUG

    # There are several cases of outcomes here
    case bikes.length
    # 1. no bikes found
    when 0

      # search for close serials
      close_bikes = search_bike_index(search_term, "close")
      puts "Searching close serials: got #{close_bikes.length}" # if $DEBUG

      case close_bikes.length
      # If there's only one match, tweet it, else send to search results
      when 0
        reply = "#{at_screen_name} Sorry, I couldn't find that bike on the Bike Index https://BikeIndex.org"
        send_tweet(reply, nil, update_opts)

      when 1
        reply = build_bike_reply("#{at_screen_name} Inexact match: serial=#{close_bikes[0]["serial"]}", close_bikes[0])
        send_tweet(reply, close_bikes[0]["large_img"], update_opts)

      else
        reply = "#{at_screen_name} Sorry, I couldn't find that bike on the Bike Index, but here are some similar serials #{@search_url}&serial=#{search_term}"
        send_tweet(reply, nil, update_opts)
      end


    # 2. a few bikes found
    when 1..3
      if bikes.length > 1
        reply = "#{at_screen_name} There are #{bikes.length} bikes with that serial number. I'll tweet them to you. #{@search_url}&serial=#{search_term}"
        send_tweet(reply, nil, update_opts)
      end

      bikes.each do |bike|
        reply = build_bike_reply(at_screen_name, bike)
        send_tweet(reply, bike["large_img"], update_opts)
      end

    # 3. There are more than 3 bikes, just send to the search results
    else
      reply = "#{at_screen_name} Whoa, there are #{bikes.length} bikes with that serial! Too many to tweet. Check here: #{@search_url}&serial=#{search_term}"
      send_tweet(reply, nil, update_opts)

    end
  end

  # Respond to tweets we missed when the script was not running
  # TODO make this run when the streaming API hiccups or any time we reconnect
  def get_missed_tweets
    # all my tweets are replys, so we can find the last thing we replied to by looking at my last tweet
    user_timeline_opts = { :count => 1}
    last_tweet = @rest_client.user_timeline(@i_am_user, user_timeline_opts)[0]
    # if there are more than 200 tweets at me since my last reply, we're going to miss some
    mentions_timeline_opts = { :count => 200, :since_id => last_tweet.in_reply_to_status_id }
    missed_tweets = @rest_client.mentions_timeline(mentions_timeline_opts)
    puts "Missed #{missed_tweets.length} tweets. Responding..."

    missed_tweets.reverse_each do |tweet|
      if (Time.now - tweet.created_at) <= @respond_history_time
        process_tweet(tweet)
      else
        puts "This one's too old. Next!"
      end
    end
  end

  # Monitors userstream (streaming API) and catches tweets
  # Most of the time we are sitting in the block in this function waiting for tweets
  def respond_to_stream
    # first, get the missed ones
    get_missed_tweets

    @stream_client.userstream do |tweet|
      process_tweet(tweet)
    end

  end
end


bot = IsItStolen.new.respond_to_stream
