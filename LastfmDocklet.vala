/**
 * Last.fm Docklet
 *
 * @author quest <quest@mac.com>
 */

public static void docklet_init(Plank.DockletManager manager) {
  manager.register_docklet(typeof (Lastfm.LastfmDocklet));
}

namespace Lastfm {
  /**
   * Resource path for the icon
   */
  public const string G_RESOURCE_PATH = "/at/greyh/lastfm";

  public class LastfmDocklet : Object, Plank.Docklet {
    public unowned string get_id() {
      return "lastfm";
    }

    public unowned string get_name() {
      return _("Last.fm");
    }

    public unowned string get_description() {
      return _("A small Last.fm docklet");
    }

    public unowned string get_icon() {
      return "resource://" + Lastfm.G_RESOURCE_PATH + "/icons/lastfm.png";
    }

    public bool is_supported() {
      return true;
    }

    public Plank.DockElement make_element(string launcher, GLib.File file) {
      return new LastfmDockItem.with_dockitem_file(file);
    }
  }
}
