using Soup;
using Json;

namespace Lastfm {
  /**
   * Represents a Last.fm track
   */
  public class Track : GLib.Object {
    public string artist_name { get; set; default = ""; }
    public string artist_mbid { get; set; default = ""; }
    public string track_name { get; set; default = ""; }
    public string track_mbid { get; set; default = ""; }
    public string album_name { get; set; default = ""; }
    public string album_mbid { get; set; default = ""; }
    public string track_url { get; set; default = ""; }
    public string image_small { get; set; default = ""; }
    public string image_medium { get; set; default = ""; }
    public string image_large { get; set; default = ""; }
    public string image_extralarge { get; set; default = ""; }
    public int64 timestamp { get; set; default = 0; }
    public string date_text { get; set; default = ""; }
    public bool is_now_playing { get; set; default = false; }
    public bool is_loved { get; set; default = false; }

    public Track() {
      GLib.Object();
    }

    public string to_string() {
      return (is_now_playing ? "♪ " : "") + @"$artist_name - $track_name" + (is_now_playing ? " ♪" : "");
    }
  }

  /**
   * Client for fetching data from Last.fm API
   */
  public class LastfmClient : GLib.Object {
    private const string API_BASE = "http://ws.audioscrobbler.com/2.0/";
    private const int CACHE_SIZE_MULTIPLIER = 3;

    private Soup.Session session;

    private int max_cache_size = 30;
    private Gee.HashMap<string, Gdk.Pixbuf> image_cache;
    private GLib.Mutex cache_mutex;

    public LastfmClient() {
      session = new Soup.Session();
      image_cache = new Gee.HashMap<string, Gdk.Pixbuf> ();
    }

    /**
     * Updates cache size based on user preferences
     */
    public void update_cache_size(int max_entries) {
      cache_mutex.lock();
      max_cache_size = max_entries * CACHE_SIZE_MULTIPLIER;

      if (image_cache.size > max_cache_size) {
        image_cache.clear();
      }

      cache_mutex.unlock();
    }

    /**
     * Fetches recent tracks for a user
     */
    public async Gee.ArrayList<Track> get_recent_tracks(string api_key, string username, int limit = 50) throws Error {
      if (api_key.length == 0 || username.length == 0) {
        throw new IOError.INVALID_ARGUMENT("API key and username are required");
      }

      var url = build_recent_tracks_url(api_key, username, limit);
      var msg = new Soup.Message("GET", url);

      var response = yield session.send_and_read_async(msg, Priority.DEFAULT, null);

      if (msg.status_code != 200) {
        throw new IOError.FAILED("API request failed with status %u: %s",
                                 msg.status_code, msg.reason_phrase);
      }

      var json_data = (string) response.get_data();
      var tracks = parse_recent_tracks_response(json_data, limit);

      return tracks;
    }

    /**
     * Builds the API URL for recent tracks
     */
    private string build_recent_tracks_url(string api_key, string username, int limit) {
      var builder = new StringBuilder(API_BASE);
      builder.append("?method=user.getrecenttracks");
      builder.append("&user=").append(Uri.escape_string(username));
      builder.append("&api_key=").append(Uri.escape_string(api_key));
      builder.append("&format=json");
      builder.append("&limit=").append(limit.to_string());
      builder.append("&extended=1");

      return builder.str;
    }

    /**
     * Parses the JSON response from Last.fm API
     */
    private Gee.ArrayList<Track> parse_recent_tracks_response(string json_data, int limit) throws Error {
      var parser = new Json.Parser();
      parser.load_from_data(json_data);

      var root = parser.get_root();
      if (root == null || root.get_node_type() != Json.NodeType.OBJECT) {
        throw new IOError.INVALID_DATA("Invalid JSON response");
      }

      var root_obj = root.get_object();

      if (root_obj.has_member("error")) {
        var error_code = (int) root_obj.get_int_member("error");
        var error_message = root_obj.get_string_member("message");
        throw new IOError.FAILED("Last.fm API error %d: %s", error_code, error_message);
      }

      if (!root_obj.has_member("recenttracks")) {
        throw new IOError.INVALID_DATA("No recenttracks in response");
      }

      var recenttracks = root_obj.get_object_member("recenttracks");
      if (!recenttracks.has_member("track")) {
        return new Gee.ArrayList<Track> ();
      }

      var tracks = new Gee.ArrayList<Track> ();
      var tracks_node = recenttracks.get_member("track");

      if (tracks_node.get_node_type() == Json.NodeType.ARRAY) {
        var tracks_array = tracks_node.get_array();
        tracks_array.foreach_element((array, index, element) => {
          try {
            // Do limit check because Last.fm has an off by 1
            // error in their API.
            if (element.get_node_type() == Json.NodeType.OBJECT && index < limit) {
              var track = parse_track(element.get_object());
              tracks.add(track);
            }
          } catch (Error e) {
            warning("LastfmClient: Failed to parse track %u: %s", (int) index, e.message);
          }
        });
      } else if (tracks_node.get_node_type() == Json.NodeType.OBJECT) {
        try {
          var track = parse_track(tracks_node.get_object());
          tracks.add(track);
        } catch (Error e) {
          warning("LastfmClient: Failed to parse single track: %s", e.message);
        }
      }

      return tracks;
    }

    /**
     * Parses a single track object from JSON
     */
    private Track parse_track(Json.Object track_obj) throws Error {
      var track = new Track();

      if (track_obj.has_member("artist")) {
        var artist_node = track_obj.get_member("artist");

        if (artist_node.get_node_type() == Json.NodeType.OBJECT) {
          var artist = track_obj.get_object_member("artist");

          if (artist.has_member("name")) {
            track.artist_name = get_json_string_member(artist, "name");
          } else {
            track.artist_name = get_json_string_member(artist, "#text");
          }

          track.artist_mbid = get_json_string_member(artist, "mbid");
        }
      }

      track.track_name = get_json_string_member(track_obj, "name");
      track.track_mbid = get_json_string_member(track_obj, "mbid");
      track.track_url = get_json_string_member(track_obj, "url");

      if (track_obj.has_member("album")) {
        var album = track_obj.get_object_member("album");
        track.album_name = get_json_string_member(album, "#text");
        track.album_mbid = get_json_string_member(album, "mbid");
      }

      if (track_obj.has_member("image")) {
        var images = track_obj.get_array_member("image");
        images.foreach_element((array, index, element) => {
          if (element.get_node_type() == Json.NodeType.OBJECT) {
            var img_obj = element.get_object();
            var size = get_json_string_member(img_obj, "size");
            var url = get_json_string_member(img_obj, "#text");

            switch (size) {
              case "small":
                track.image_small = url;
                break;
              case "medium":
                track.image_medium = url;
                break;
              case "large":
                track.image_large = url;
                break;
              case "extralarge":
                track.image_extralarge = url;
                break;
            }
          }
        });
      }

      if (track_obj.has_member("date")) {
        var date_obj = track_obj.get_object_member("date");
        if (date_obj.has_member("uts")) {
          track.timestamp = int.parse(date_obj.get_string_member("uts"));
        }
        track.date_text = get_json_string_member(date_obj, "#text");
      }

      if (track_obj.has_member("@attr")) {
        var attr_obj = track_obj.get_object_member("@attr");
        track.is_now_playing = attr_obj.has_member("nowplaying");
      }

      if (track_obj.has_member("loved")) {
        track.is_loved = get_json_string_member(track_obj, "loved") == "1";
      }

      return track;
    }

    /**
     * Helper method to safely get string members from JSON objects
     */
    private string get_json_string_member(Json.Object obj, string member_name) {
      if (obj.has_member(member_name)) {
        var node = obj.get_member(member_name);
        if (node.get_node_type() == Json.NodeType.NULL) {
          return "";
        }
        if (node.get_node_type() == Json.NodeType.VALUE) {
          return obj.get_string_member(member_name);
        }
      }
      return "";
    }

    /**
     * Downloads album art for a track with simple caching
     */
    public async Gdk.Pixbuf? get_album_art(Track track, int size) throws Error {
      var image_url = get_best_image_url(track);

      if (image_url.length == 0) {
        return null;
      }

      var cache_key = @"$image_url:$size";

      cache_mutex.lock();

      Gdk.Pixbuf? result = null;
      if (image_cache.has_key(cache_key)) {
        result = image_cache[cache_key];
      }

      cache_mutex.unlock();

      if (result != null) {
        return result;
      }

      var msg = new Soup.Message("GET", image_url);
      var response = yield session.send_and_read_async(msg, Priority.DEFAULT, null);

      if (msg.status_code != 200) {
        throw new IOError.FAILED("Failed to download image: HTTP %u", msg.status_code);
      }

      var data = response.get_data();
      var stream = new MemoryInputStream.from_data(data);
      var pixbuf = new Gdk.Pixbuf.from_stream_at_scale(stream, size, size, true);

      cache_mutex.lock();

      if (image_cache.size >= max_cache_size) {
        image_cache.clear();
      }

      image_cache[cache_key] = pixbuf;
      cache_mutex.unlock();

      return pixbuf;
    }

    /**
     * Gets the best available image URL for a track
     */
    private string get_best_image_url(Track track) {
      if (track.image_extralarge.length > 0) {
        return track.image_extralarge;
      } else if (track.image_large.length > 0) {
        return track.image_large;
      } else if (track.image_medium.length > 0) {
        return track.image_medium;
      } else if (track.image_small.length > 0) {
        return track.image_small;
      }
      return "";
    }
  }
}
