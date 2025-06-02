using Plank;
using Cairo;

namespace Lastfm {
  public class LastfmDockItem : DockletItem {
    private const uint FETCH_INTERVAL_SECONDS = 60;
    private const int ALBUM_ICON_SIZE = 256;
    private const int MENU_ICON_SIZE = 32;
    private const int MAX_TRACK_DISPLAY_CHARS = 40;

    Gdk.Pixbuf icon_pixbuf;
    LastfmPreferences prefs;

    private uint fetch_timer_id = 0;
    private uint debounce_timer_id = 0;
    private bool initial_fetch_done = false;

    private LastfmClient lastfm_client;
    private Gee.ArrayList<Track> recent_tracks;
    private GLib.Mutex tracks_mutex;

    private Gtk.Menu? cached_menu = null;
    private bool menu_needs_rebuild = true;
    private GLib.Mutex menu_mutex;

    public LastfmDockItem.with_dockitem_file(GLib.File file) {
      GLib.Object(Prefs : new LastfmPreferences.with_file(file));
    }

    construct {
      prefs = (LastfmPreferences) Prefs;
      Icon = "resource://" + Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png";

      try {
        icon_pixbuf = new Gdk.Pixbuf.from_resource(Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png");
      } catch (Error e) {
        warning("Error: " + e.message);
      }

      lastfm_client = new LastfmClient();
      recent_tracks = new Gee.ArrayList<Track> ();

      lastfm_client.update_cache_size(prefs.MaxEntries);

      setup_preference_monitoring();

      GLib.Timeout.add(500, () => {
        trigger_fetch();
        return false;
      });
    }

    ~LastfmDockItem() {
      if (fetch_timer_id != 0) {
        GLib.Source.remove(fetch_timer_id);
        fetch_timer_id = 0;
      }
      if (debounce_timer_id != 0) {
        GLib.Source.remove(debounce_timer_id);
        debounce_timer_id = 0;
      }
      if (cached_menu != null) {
        cached_menu.destroy();
      }
    }

    /**
     * Sets up monitoring for preference changes
     */
    private void setup_preference_monitoring() {
      prefs.notify.connect((pspec) => {
        switch (pspec.name) {
          case "APIKey":
          case "Username":
            schedule_debounced_fetch();
            break;
          case "MaxEntries":
            lastfm_client.update_cache_size(prefs.MaxEntries);
            schedule_debounced_fetch();
            break;
          case "RoundedCorners":
            schedule_debounced_fetch();
            break;
        }
      });
    }

    /**
     * Schedules a debounced fetch to handle multiple rapid preference changes
     */
    private void schedule_debounced_fetch() {
      if (debounce_timer_id != 0) {
        GLib.Source.remove(debounce_timer_id);
      }

      debounce_timer_id = GLib.Timeout.add(500, () => {
        debounce_timer_id = 0;
        trigger_fetch();
        return false;
      });
    }

    /**
     * Triggers a fetch and sets up the recurring timer
     */
    private void trigger_fetch() {
      fetch.begin();

      if (!initial_fetch_done) {
        initial_fetch_done = true;
        setup_recurring_timer();
      }
    }

    /**
     * Sets up the recurring fetch timer
     */
    private void setup_recurring_timer() {
      if (fetch_timer_id != 0) {
        GLib.Source.remove(fetch_timer_id);
      }

      fetch_timer_id = GLib.Timeout.add_seconds(FETCH_INTERVAL_SECONDS, () => {
        fetch.begin();
        return true;
      });
    }

    private async void fetch() {
      if (prefs.APIKey.length == 0 || prefs.Username.length == 0) {
        message("Skipping fetch - missing API key or username");
        return;
      }

      try {
        var tracks = yield lastfm_client.get_recent_tracks(prefs.APIKey, prefs.Username, prefs.MaxEntries);

        tracks_mutex.lock();
        recent_tracks = tracks;
        tracks_mutex.unlock();

        yield update_docklet_icon();
        yield rebuild_menu_cache();
      } catch (Error e) {
        warning("Failed to fetch tracks: %s", e.message);
      }
    }

    /**
     * Updates the docklet icon with the most recent track's album art
     */
    private async void update_docklet_icon() {
      tracks_mutex.lock();
      Track? most_recent_track = recent_tracks.size > 0 ? recent_tracks[0] : null;
      tracks_mutex.unlock();

      if (most_recent_track == null) {
        return;
      }

      Text = most_recent_track.to_string();

      try {
        var pixbuf = yield lastfm_client.get_album_art(most_recent_track, ALBUM_ICON_SIZE);

        if (pixbuf != null) {
          ForcePixbuf = prefs.RoundedCorners ? round_pixbuf_corners(pixbuf) : pixbuf;
        } else {
          reset_to_default_icon();
        }
      } catch (Error e) {
        warning("Failed to load album art: %s", e.message);
        reset_to_default_icon();
      }
    }

    /**
     * Resets the docklet icon to the default Last.fm icon
     */
    private void reset_to_default_icon() {
      ForcePixbuf = icon_pixbuf;
    }

    /**
     * Creates a pixbuf with rounded corners
     */
    private Gdk.Pixbuf round_pixbuf_corners(Gdk.Pixbuf source) {
      if (source == null) {
        return source;
      }

      int width = source.get_width();
      int height = source.get_height();

      var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, width, height);
      var cr = new Cairo.Context(surface);

      double radius = double.min(width, height) * 0.15;

      cr.new_sub_path();
      cr.arc(radius, radius, radius, Math.PI, 3 * Math.PI / 2);
      cr.arc(width - radius, radius, radius, 3 * Math.PI / 2, 0);
      cr.arc(width - radius, height - radius, radius, 0, Math.PI / 2);
      cr.arc(radius, height - radius, radius, Math.PI / 2, Math.PI);
      cr.close_path();

      cr.clip();

      Gdk.cairo_set_source_pixbuf(cr, source, 0, 0);
      cr.paint();

      var rounded_pixbuf = Gdk.pixbuf_get_from_surface(surface, 0, 0, width, height);

      return rounded_pixbuf;
    }

    /**
     * Rebuilds the menu cache in the background
     */
    private async void rebuild_menu_cache() {
      DockController? controller = get_dock();
      if (controller == null) {
        return;
      }

      menu_mutex.lock();

      if (cached_menu != null) {
        cached_menu.destroy();
        cached_menu = null;
      }

      cached_menu = build_tracks_menu(controller);
      menu_needs_rebuild = false;

      menu_mutex.unlock();
    }

    /**
     * Thread-safe method to get a copy of the current tracks
     */
    private Gee.ArrayList<Track> get_tracks_copy() {
      tracks_mutex.lock();
      var tracks_copy = new Gee.ArrayList<Track> ();
      foreach (var track in recent_tracks) {
        tracks_copy.add(track);
      }
      tracks_mutex.unlock();
      return tracks_copy;
    }

    /**
     * Thread-safe method to get track count
     */
    private int get_track_count() {
      tracks_mutex.lock();
      var count = recent_tracks.size;
      tracks_mutex.unlock();
      return count;
    }

    protected override AnimationType on_clicked(PopupButton button, Gdk.ModifierType mod, uint32 event_time) {
      if ((button & PopupButton.LEFT) != 0) {
        show_tracks_menu();
      }

      return AnimationType.NONE;
    }

    private void on_menu_show() {
      DockController? controller = get_dock();
      if (controller == null) {
        return;
      }

      controller.window.update_icon_regions();
      controller.hover.hide();
      controller.renderer.animated_draw();
    }

    private void on_menu_hide() {
      DockController? controller = get_dock();
      if (controller == null) {
        return;
      }

      controller.window.update_icon_regions();
      controller.renderer.animated_draw();

      controller.hide_manager.update_hovered();
      if (!controller.hide_manager.Hovered) {
        controller.window.update_hovered(0, 0);
      }
    }

    /**
     * Shows the cached menu (instant display)
     */
    private void show_tracks_menu() {
      DockController? controller = get_dock();
      if (controller == null) {
        return;
      }

      menu_mutex.lock();

      if (cached_menu == null) {
        cached_menu = build_tracks_menu(controller);
        menu_needs_rebuild = false;
      }

      var menu_to_show = cached_menu;

      menu_mutex.unlock();

      if (menu_to_show != null) {
        menu_to_show.show_all();

        Gtk.Requisition requisition;
        menu_to_show.get_preferred_size(null, out requisition);

        int x, y;
        controller.position_manager.get_menu_position(this, requisition, out x, out y);

        Gdk.Gravity gravity;
        Gdk.Gravity flipped_gravity;

        switch (controller.position_manager.Position) {
        case Gtk.PositionType.BOTTOM :
          gravity = Gdk.Gravity.NORTH;
          flipped_gravity = Gdk.Gravity.SOUTH;
          break;
        case Gtk.PositionType.TOP :
          gravity = Gdk.Gravity.SOUTH;
          flipped_gravity = Gdk.Gravity.NORTH;
          break;
        case Gtk.PositionType.LEFT :
          gravity = Gdk.Gravity.EAST;
          flipped_gravity = Gdk.Gravity.WEST;
          break;
        case Gtk.PositionType.RIGHT :
          gravity = Gdk.Gravity.WEST;
          flipped_gravity = Gdk.Gravity.EAST;
          break;
          default :
          gravity = Gdk.Gravity.NORTH;
          flipped_gravity = Gdk.Gravity.SOUTH;
          break;
        }

        menu_to_show.popup_at_rect(
                                   controller.window.get_screen().get_root_window(),
                                   Gdk.Rectangle() {
          x = x,
          y = y,
          width = 1,
          height = 1,
        },
                                   gravity,
                                   flipped_gravity,
                                   null
        );
      }
    }

    /**
     * Builds the tracks menu (called only when cache needs rebuilding)
     */
    private Gtk.Menu build_tracks_menu(DockController controller) {
      var tracks = get_tracks_copy();

      if (tracks.size == 0) {
        return build_empty_menu(controller);
      }

      var menu = new Gtk.Menu();
      menu.show.connect(on_menu_show);
      menu.hide.connect(on_menu_hide);
      menu.attach_to_widget(controller.window, null);

      var header_item = create_header_menu_item();
      menu.append(header_item);

      var separator = new Gtk.SeparatorMenuItem();
      menu.append(separator);

      for (int i = 0; i < tracks.size; i++) {
        var track = tracks[i];
        var track_item = create_track_menu_item(track, i);
        menu.append(track_item);
      }

      return menu;
    }

    /**
     * Builds the empty menu (called only when cache needs rebuilding)
     */
    private Gtk.Menu build_empty_menu(DockController controller) {
      var menu = new Gtk.Menu();
      menu.show.connect(on_menu_show);
      menu.hide.connect(on_menu_hide);
      menu.attach_to_widget(controller.window, null);

      var empty_item = new Gtk.MenuItem.with_label(_("No recent tracks found"));
      empty_item.set_sensitive(false);
      menu.append(empty_item);

      var separator = new Gtk.SeparatorMenuItem();
      menu.append(separator);

      var refresh_item = new Gtk.MenuItem.with_label(_("Refresh Now"));
      refresh_item.activate.connect(() => {
        fetch.begin();
      });
      menu.append(refresh_item);

      return menu;
    }

    /**
     * Creates a header menu item showing the user info
     */
    private Gtk.MenuItem create_header_menu_item() {
      var track_count = get_track_count();
      var header_text = _("Recent Tracks for %s (%d)").printf(prefs.Username, track_count);

      var header_item = new Gtk.MenuItem.with_label(header_text);
      header_item.set_sensitive(false);

      var label = header_item.get_child() as Gtk.Label;
      if (label != null) {
        label.set_markup("<b>" + GLib.Markup.escape_text(header_text) + "</b>");
      }

      return header_item;
    }

    /**
     * Creates a menu item for a track
     */
    private Gtk.MenuItem create_track_menu_item(Track track, int index) {
      var menu_item = new Gtk.MenuItem();

      var hbox = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
      hbox.set_margin_start(8);
      hbox.set_margin_end(8);
      hbox.set_margin_top(4);
      hbox.set_margin_bottom(4);

      var album_art = new Gtk.Image();
      album_art.set_size_request(MENU_ICON_SIZE, MENU_ICON_SIZE);
      load_album_art_async.begin(album_art, track);
      hbox.pack_start(album_art, false, false, 0);

      var text_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);

      var track_label = new Gtk.Label(null);
      var track_text = track.track_name;
      if (track.is_now_playing) {
        track_text = "♪ " + track_text + " ♪";
        track_label.set_markup("<b>" + GLib.Markup.escape_text(track_text) + "</b>");
      } else {
        track_label.set_text(track_text);
      }
      track_label.set_halign(Gtk.Align.START);
      track_label.set_ellipsize(Pango.EllipsizeMode.END);
      track_label.set_max_width_chars(MAX_TRACK_DISPLAY_CHARS);
      text_box.pack_start(track_label, false, false, 0);

      var artist_label = new Gtk.Label(track.artist_name);
      artist_label.set_halign(Gtk.Align.START);
      artist_label.set_ellipsize(Pango.EllipsizeMode.END);
      artist_label.set_max_width_chars(MAX_TRACK_DISPLAY_CHARS);
      artist_label.set_markup("<small>" + GLib.Markup.escape_text(track.artist_name) + "</small>");
      text_box.pack_start(artist_label, false, false, 0);

      if (track.album_name.length > 0) {
        var album_label = new Gtk.Label(null);
        album_label.set_halign(Gtk.Align.START);
        album_label.set_ellipsize(Pango.EllipsizeMode.END);
        album_label.set_max_width_chars(MAX_TRACK_DISPLAY_CHARS);
        album_label.set_markup("<small><i>" + GLib.Markup.escape_text(track.album_name) + "</i></small>");
        text_box.pack_start(album_label, false, false, 0);
      }

      hbox.pack_start(text_box, true, true, 0);

      if (track.is_loved) {
        var heart_label = new Gtk.Label(null);
        heart_label.set_markup("<span color='red'>♥</span>");
        hbox.pack_end(heart_label, false, false, 0);
      }

      if (!track.is_now_playing && track.date_text.length > 0) {
        var time_label = new Gtk.Label(null);
        var time_text = format_relative_time(track.timestamp);
        time_label.set_markup("<small><span color='gray'>" + GLib.Markup.escape_text(time_text) + "</span></small>");
        hbox.pack_end(time_label, false, false, 0);
      }

      menu_item.add(hbox);

      menu_item.activate.connect(() => {
        open_lastfm_track_page(track);
      });

      return menu_item;
    }

    /**
     * Loads album art asynchronously
     */
    private async void load_album_art_async(Gtk.Image image_widget, Track track) {
      try {
        var pixbuf = yield lastfm_client.get_album_art(track, MENU_ICON_SIZE);

        if (pixbuf != null) {
          image_widget.set_from_pixbuf(pixbuf);
          return;
        }
      } catch (Error e) {
        warning("Failed to load album art: %s", e.message);
      }

      image_widget.set_from_icon_name("audio-x-generic", Gtk.IconSize.LARGE_TOOLBAR);
    }

    /**
     * Formats timestamp as relative time (e.g., "2 minutes ago")
     */
    private string format_relative_time(int64 timestamp) {
      if (timestamp == 0) {
        return "";
      }

      var now = new DateTime.now_local();
      var track_time = new DateTime.from_unix_local(timestamp);
      var diff_seconds = (int64) (now.difference(track_time) / TimeSpan.SECOND);

      if (diff_seconds < 60) {
        return _("Just now");
      } else if (diff_seconds < 3600) {
        var minutes = (long) (diff_seconds / 60);
        return ngettext("%ld minute ago", "%ld minutes ago", (ulong) minutes).printf(minutes);
      } else if (diff_seconds < 86400) {
        var hours = (long) (diff_seconds / 3600);
        return ngettext("%ld hour ago", "%ld hours ago", (ulong) hours).printf(hours);
      } else {
        var days = (long) (diff_seconds / 86400);
        return ngettext("%ld day ago", "%ld days ago", (ulong) days).printf(days);
      }
    }

    /**
     * Opens the Last.fm page for a track
     */
    private void open_lastfm_track_page(Track track) {
      if (track.track_url.length > 0) {
        try {
          Gtk.show_uri_on_window(null, track.track_url, Gdk.CURRENT_TIME);
        } catch (Error e) {
          warning("Failed to open URL %s: %s", track.track_url, e.message);
        }
      } else {
        message("No URL available for track: %s - %s", track.artist_name, track.track_name);
      }
    }

    /**
     * Creates and shows the preferences dialog
     */
    private void show_preferences_dialog() {
      var dialog = new Gtk.Dialog.with_buttons(
                                               _("Last.fm Preferences"),
                                               null,
                                               Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
                                               _("_Cancel"), Gtk.ResponseType.CANCEL,
                                               _("_OK"), Gtk.ResponseType.OK
      );

      dialog.set_resizable(false);

      var content_area = dialog.get_content_area();
      content_area.set_spacing(12);
      content_area.set_margin_start(12);
      content_area.set_margin_end(12);
      content_area.set_margin_top(12);
      content_area.set_margin_bottom(12);

      var grid = new Gtk.Grid();
      grid.set_row_spacing(12);
      grid.set_column_spacing(12);
      grid.set_hexpand(true);

      var api_key_label = new Gtk.Label(_("API Key:"));
      api_key_label.set_halign(Gtk.Align.START);
      var api_key_entry = new Gtk.Entry();
      api_key_entry.set_text(prefs.APIKey);
      api_key_entry.set_hexpand(true);
      api_key_entry.set_placeholder_text(_("Enter your Last.fm API key"));

      var username_label = new Gtk.Label(_("Username:"));
      username_label.set_halign(Gtk.Align.START);
      var username_entry = new Gtk.Entry();
      username_entry.set_text(prefs.Username);
      username_entry.set_hexpand(true);
      username_entry.set_placeholder_text(_("Enter your Last.fm username"));

      var max_entries_label = new Gtk.Label(_("Max Tracks:"));
      max_entries_label.set_halign(Gtk.Align.START);
      var max_entries_spin = new Gtk.SpinButton.with_range(1, 200, 1);
      max_entries_spin.set_value(prefs.MaxEntries);
      max_entries_spin.set_hexpand(true);

      var rounded_corners_label = new Gtk.Label(_("Rounded Corners:"));
      rounded_corners_label.set_halign(Gtk.Align.START);
      var rounded_corners_switch = new Gtk.Switch();
      rounded_corners_switch.set_active(prefs.RoundedCorners);
      rounded_corners_switch.set_halign(Gtk.Align.START);

      var help_label = new Gtk.Label(_("Get your API key from: https://www.last.fm/api/account/create"));
      help_label.set_halign(Gtk.Align.START);
      help_label.set_markup("<small><i>" + help_label.get_text() + "</i></small>");
      help_label.set_line_wrap(true);

      grid.attach(api_key_label, 0, 0, 1, 1);
      grid.attach(api_key_entry, 1, 0, 1, 1);
      grid.attach(username_label, 0, 1, 1, 1);
      grid.attach(username_entry, 1, 1, 1, 1);
      grid.attach(max_entries_label, 0, 2, 1, 1);
      grid.attach(max_entries_spin, 1, 2, 1, 1);
      grid.attach(rounded_corners_label, 0, 3, 1, 1);
      grid.attach(rounded_corners_switch, 1, 3, 1, 1);
      grid.attach(help_label, 0, 4, 2, 1);

      content_area.pack_start(grid, true, true, 0);

      dialog.show_all();

      dialog.response.connect((response_id) => {
        if (response_id == Gtk.ResponseType.OK) {
          prefs.APIKey = api_key_entry.get_text().strip();
          prefs.Username = username_entry.get_text().strip();
          prefs.MaxEntries = (int) max_entries_spin.get_value();
          prefs.RoundedCorners = rounded_corners_switch.get_active();

          prefs.notify_property("APIKey");
          prefs.notify_property("Username");
          prefs.notify_property("MaxEntries");
          prefs.notify_property("RoundedCorners");
        }
        dialog.destroy();
      });
    }

    public override Gee.ArrayList<Gtk.MenuItem> get_menu_items() {
      var items = new Gee.ArrayList<Gtk.MenuItem> ();

      var preferences_item = new Gtk.MenuItem.with_label(_("Preferences"));
      preferences_item.activate.connect(() => {
        show_preferences_dialog();
      });
      items.add(preferences_item);

      var separator = new Gtk.SeparatorMenuItem();
      items.add(separator);

      var about_item = new Gtk.MenuItem.with_label(_("About"));
      about_item.activate.connect(() => {
        show_about_dialog();
      });
      items.add(about_item);

      return items;
    }

    /**
     * Shows an about dialog
     */
    private void show_about_dialog() {
      var about_dialog = new Gtk.AboutDialog();
      about_dialog.set_program_name(_("Last.fm Docklet"));
      about_dialog.set_version("0.1.0");
      about_dialog.set_comments(_("Lists recent tracks scrobbled to Last.fm"));
      about_dialog.set_website("https://github.com/zquestz/lastfm-docklet");
      about_dialog.set_website_label(_("GitHub Repository"));
      about_dialog.set_license_type(Gtk.License.GPL_3_0);

      try {
        var logo = new Gdk.Pixbuf.from_resource(Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png");

        int width, height;
        Gtk.icon_size_lookup(Gtk.IconSize.DIALOG, out width, out height);

        logo = DrawingService.ar_scale(logo, width, height);

        about_dialog.set_logo(logo);
      } catch (Error e) {
        warning("Error: " + e.message);
      }

      about_dialog.run();
      about_dialog.destroy();
    }
  }
}
