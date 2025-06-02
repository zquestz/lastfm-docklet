using Plank;

namespace Lastfm {
  public class LastfmPreferences : DockItemPreferences {
    [Description(nick = "api-key", blurb = "Last.fm API key")]
    public string APIKey { get; set; default = ""; }

    [Description(nick = "username", blurb = "Last.fm username")]
    public string Username { get; set; default = ""; }

    [Description(nick = "max-entries", blurb = "Max number of scrobbles to show")]
    public int MaxEntries { get; set; default = 10; }

    [Description(nick = "rounded-corners", blurb = "Round the corners of the dock icon")]
    public bool RoundedCorners { get; set; default = false; }

    public LastfmPreferences.with_file(GLib.File file) {
      base.with_file(file);
    }

    protected override void reset_properties() {
      APIKey = "";
      Username = "";
      MaxEntries = 10;
      RoundedCorners = false;
    }
  }
}
