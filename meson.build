project(
  'docklet-lastfm',
  'vala',
  'c',
  version: '0.1.0',
)

# Dependencies
gtk_dep = dependency('gtk+-3.0')
plank_dep = dependency('plank')
soup_dep = dependency('libsoup-3.0')
json_dep = dependency('json-glib-1.0')
i18n = import('i18n')

# Configure the build
customconf = configuration_data()
customconf.set('GETTEXT_PACKAGE', meson.project_name())

# Generate resource file
gnome = import('gnome')
resources = gnome.compile_resources('resources', 'lastfm.gresource.xml', source_dir: '.', c_name: 'resources')

add_project_arguments(
  [
    '-Wno-discarded-qualifiers',
    '-Wno-incompatible-pointer-types',
    '-Wno-unused',
    '-Wl,--enable-new-dtags',

    '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
  ],
  language: 'c',
)

# Source files
sources = [
  'LastfmDocklet.vala',
  'LastfmDockItem.vala',
  'LastfmPreferences.vala',
  'LastfmClient.vala',
  resources,
]

# Build the shared module
shared_module(
  'docklet-lastfm',
  sources,
  dependencies: [gtk_dep, plank_dep, soup_dep, json_dep],
  install: true,
  install_dir: join_paths(get_option('libdir'), 'plank/docklets'),
)

subdir('po')
