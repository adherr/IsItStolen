What it is
==========

A script that connects to a [Twitter Userstream][1] and responds to
all tweets that mention the user it's connected as. This script
queries [BikeIndex.org][2] about the contents of the messages it
receives and responds with a short description of the bike and its
stolen status using the [Twitter REST API][3].

[1]: https://dev.twitter.com/docs/streaming-apis/streams/user "Twitter User streams API"
[2]: https://BikeIndex.org "BikeIndex.org"
[3]: https://dev.twitter.com/docs/api/1.1/post/statuses/update "Twitter update status"

TO DO
=====

- All caps the environment variables
- Search nearby serials if no hits are found with the exact match
- Better parsing of incoming tweets
- Handle Twitter exceptions reasonably
- Persistently keep track of last tweet processed so we can respond to
  old tweets on startup back to where we left of in case of streaming
  API problems, Heroku dyno balancing, etc
- Send pictures? Only stolen bikes? ???
