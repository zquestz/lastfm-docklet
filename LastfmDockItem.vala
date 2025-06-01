using Plank;
using Cairo;

namespace Lastfm {
  public class LastfmDockItem : DockletItem {
    private const uint FETCH_INTERVAL_SECONDS = 60;

    Gdk.Pixbuf icon_pixbuf;
    LastfmPreferences prefs;

    private uint fetch_timer_id = 0;
    private uint debounce_timer_id = 0;
    private bool initial_fetch_done = false;

    public LastfmDockItem.with_dockitem_file(GLib.File file) {
      GLib.Object(Prefs: new LastfmPreferences.with_file(file));
    }

    construct {
      prefs = (LastfmPreferences) Prefs;
      Icon = "resource://" + Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png";

      try {
        icon_pixbuf = new Gdk.Pixbuf.from_resource(Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png");
      } catch (Error e) {
        warning("Error: " + e.message);
      }

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
    }

    /**
     * Sets up monitoring for preference changes
     */
    private void setup_preference_monitoring() {
      prefs.notify["APIKey"].connect(() => {
        schedule_debounced_fetch();
      });

      prefs.notify["Username"].connect(() => {
        schedule_debounced_fetch();
      });

      prefs.notify["MaxEntries"].connect(() => {
        schedule_debounced_fetch();
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
      fetch();

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
        fetch();
        return true;
      });

      message("Recurring fetch timer started (interval: %u seconds)", FETCH_INTERVAL_SECONDS);
    }

    /**
     * Fetches recent tracks from Last.fm API
     * This method will be implemented in the next phase
     */
    private void fetch() {
      if (prefs.APIKey.length == 0 || prefs.Username.length == 0) {
        message("Skipping fetch - missing API key or username");
        return;
      }

      message("Fetching recent tracks for user: %s (limit: %d)", prefs.Username, prefs.MaxEntries);
    }

    protected override AnimationType on_clicked(PopupButton button, Gdk.ModifierType mod, uint32 event_time) {
      if (button == PopupButton.LEFT) {
        return AnimationType.BOUNCE;
      }

      return AnimationType.NONE;
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
      grid.attach(help_label, 0, 3, 2, 1);

      content_area.pack_start(grid, true, true, 0);

      dialog.show_all();

      dialog.response.connect((response_id) => {
        if (response_id == Gtk.ResponseType.OK) {
          prefs.APIKey = api_key_entry.get_text().strip();
          prefs.Username = username_entry.get_text().strip();
          prefs.MaxEntries = (int) max_entries_spin.get_value();

          prefs.notify_property("APIKey");
          prefs.notify_property("Username");
          prefs.notify_property("MaxEntries");

          message("Preferences saved - API Key: %s, Username: %s, Max Entries: %d",
                  prefs.APIKey.length > 0 ? "[SET]" : "[EMPTY]",
                  prefs.Username,
                  prefs.MaxEntries);
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
      about_dialog.set_version("0.0.1");
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
