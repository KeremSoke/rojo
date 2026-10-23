project('rojo', 'vala', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.59')

gnome = import('gnome')
cc = meson.get_compiler('c')
valac = meson.get_compiler('vala')

libexecdir = get_option('prefix') / get_option('libexecdir')

glib_dep = dependency('glib-2.0', version: '>= 2.74')
gio_dep = dependency('gio-2.0', version: '>= 2.74')
xcb_dep = dependency('xcb', required: get_option('x11'))
xcb_randr_dep = dependency('xcb-randr', required: get_option('x11'))
wayland_dep = dependency('wayland-client', required: get_option('wayland'))
wayland_scanner_dep = dependency('wayland-scanner', native: true, required: get_option('wayland'))

c_args = [
  '-DG_LOG_DOMAIN="rojo"',
  '-DPACKAGE_VERSION="@0@"'.format(meson.project_version()),
]
gamma_sources = files('src/gamma/nl-gamma.c')
gamma_deps = [glib_dep]

if xcb_dep.found() and xcb_randr_dep.found()
  c_args += '-DHAVE_X11'
  gamma_sources += files('src/gamma/nl-gamma-x11.c')
  gamma_deps += [xcb_dep, xcb_randr_dep]
endif

if wayland_dep.found() and wayland_scanner_dep.found()
  wayland_scanner = find_program(wayland_scanner_dep.get_variable(pkgconfig: 'wayland_scanner'))
  protocol = files('protocol/wlr-gamma-control-unstable-v1.xml')
  c_args += '-DHAVE_WAYLAND'
  gamma_sources += [
    files('src/gamma/nl-gamma-wayland.c'),
    custom_target('gamma-control-client-header',
      input: protocol,
      output: 'wlr-gamma-control-unstable-v1-client-protocol.h',
      command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@']),
    custom_target('gamma-control-code',
      input: protocol,
      output: 'wlr-gamma-control-unstable-v1-protocol.c',
      command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@']),
  ]
  gamma_deps += wayland_dep
endif

if not c_args.contains('-DHAVE_X11') and not c_args.contains('-DHAVE_WAYLAND')
  error('Neither the X11 nor the Wayland backend can be built')
endif

add_project_arguments(c_args, '-w', language: 'c')

gamma_lib = static_library('nl-gamma', gamma_sources,
  include_directories: include_directories('src/gamma'),
  dependencies: gamma_deps)

gamma_dep = declare_dependency(
  link_with: gamma_lib,
  include_directories: include_directories('src/gamma'),
  sources: files('src/gamma/nl-gamma.vapi'))

core_sources = files(
  'src/colorramp.vala',
  'src/schedule.vala',
  'src/clock-monitor.vala',
  'src/location.vala',
)

core_deps = [glib_dep, gio_dep, valac.find_library('posix'), cc.find_library('m')]

executable('rojo',
  core_sources,
  'src/gamma.vala',
  'src/manager.vala',
  'src/service.vala',
  'src/main.vala',
  dependencies: core_deps + [gamma_dep],
  install: true,
  install_dir: get_option('libexecdir'))

subdir('data')

test_env = environment()
test_env.set('GSETTINGS_BACKEND', 'memory')
test_env.set('GSETTINGS_SCHEMA_DIR', meson.current_build_dir() / 'data')

test('schedule',
  executable('test-schedule',
    core_sources,
    'tests/test-schedule.vala',
    dependencies: core_deps),
  env: test_env,
  depends: compiled_schemas)
