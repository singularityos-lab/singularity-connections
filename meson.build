project('singularity-connections', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
fs = import('fs')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-connections"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4', version: '>= 4.16')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
secret_dep = dependency('libsecret-1')
freerdp_dep = dependency('freerdp3', required: get_option('rdp'))
freerdp_client_dep = dependency('freerdp-client3', required: get_option('rdp'))
winpr_dep = dependency('winpr3', required: get_option('rdp'))

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

sources = files(
  'src/store.vala',
  'src/window.vala',
  'src/search.vala',
  'src/app.vala',
)
deps = [gtk_dep, gee_dep, json_dep, secret_dep, libsingularity_dep]
vala_args = ['--vapidir=' + meson.current_source_dir() / 'vapi']

link_with = []
have_rdp = freerdp_dep.found() and freerdp_client_dep.found() and winpr_dep.found()
if have_rdp
  rdp_bridge = static_library('rdp-bridge', 'src/rdp-bridge.c',
    dependencies: [dependency('glib-2.0'), freerdp_dep, freerdp_client_dep, winpr_dep])
  sources += files('src/rdp.vala')
  link_with += rdp_bridge
  vala_args += ['--pkg=rdpbridge']
else
  sources += files('src/rdp-missing.vala')
endif

executable('singularity-connections',
  sources,
  vala_args: vala_args,
  include_directories: include_directories('src'),
  link_with: link_with,
  dependencies: deps,
  install: true
)

install_data('data/dev.sinty.connections.xml',
  install_dir: get_option('datadir') / 'mime' / 'packages'
)
install_data('data/dev.sinty.connections.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.connections.search-provider.ini',
  rename: 'dev.sinty.connections.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.connections.service.in',
  output: 'dev.sinty.connections.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

if fs.exists('data/icons/dev.sinty.connections.svg')
  install_data('data/icons/dev.sinty.connections.svg',
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
  )
endif

test_des = executable('des-test', files('tests/des_test.vala'),
  dependencies: [gtk_dep, gee_dep, libsingularity_dep])
test('des', test_des)
test_address = executable('address-test', files('src/store.vala', 'tests/address_test.vala'),
  dependencies: [dependency('gio-2.0'), gee_dep, json_dep, secret_dep])
test('address', test_address)
