install_data('org.mate.rojo.nightlight.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')

# For running the daemon and tests from the build directory.
compiled_schemas = gnome.compile_schemas(build_by_default: true)

conf = configuration_data()
conf.set('libexecdir', libexecdir)

configure_file(
  input: 'org.mate.rojo.service.in',
  output: 'org.mate.rojo.service',
  configuration: conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services')

install_data('org.mate.rojo.NightLight.xml',
  install_dir: get_option('datadir') / 'dbus-1' / 'interfaces')

if get_option('autostart')
  configure_file(
    input: 'rojo.desktop.in',
    output: 'rojo.desktop',
    configuration: conf,
    install_dir: get_option('sysconfdir') / 'xdg' / 'autostart')
endif

if get_option('geoclue_conf')
  install_data('rojo.geoclue.conf',
    rename: 'rojo.conf',
    install_dir: get_option('sysconfdir') / 'geoclue' / 'conf.d')
endif

gnome.post_install(glib_compile_schemas: true)
