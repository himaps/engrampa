# peony-qt (UKUI) 右键菜单插件
#
# 纯接口实现:只需 Qt5 + libpeony-dev 的头文件(peony-qt/*.h),
# 不链接 libpeony(插件由 peony 进程经 QPluginLoader 实例化)。
# 头文件来源:麒麟归档的 libpeony-dev(deb 解包到 /usr/include,
# 见 packaging/kylin/v10sp1/build-main.sh),或在装有
# libpeony-dev 的系统上直接构建。依赖不齐时静默跳过。

peony_plugin_summary = 'no (Qt5 or peony headers unavailable)'

cpp_found = add_languages('cpp', required: false)

if get_option('peony-actions') and cpp_found
  qt5core_dep    = dependency('Qt5Core', required: false)
  qt5gui_dep     = dependency('Qt5Gui', required: false)
  qt5widgets_dep = dependency('Qt5Widgets', required: false)
  glib_dep_peony = dependency('glib-2.0')
  gio_dep_peony  = dependency('gio-2.0')

  cxx = meson.get_compiler('cpp')
  have_peony_headers = cxx.has_header('peony-qt/menu-plugin-iface.h')

  if qt5core_dep.found() and qt5gui_dep.found() and qt5widgets_dep.found() and have_peony_headers
    qt5 = import('qt5')
    moc_h = qt5.preprocess(moc: 'peony-engrampa-plugin.h',
                           dependencies: [qt5core_dep, qt5widgets_dep])

    shared_module('peony-menu-plugin-engrampa',
      ['peony-engrampa-plugin.cpp', moc_h],
      dependencies: [qt5core_dep, qt5gui_dep, qt5widgets_dep,
                     glib_dep_peony, gio_dep_peony],
      include_directories: config_inc,
      install: true,
      install_dir: join_paths(get_option('prefix'), get_option('libdir'),
                              'peony-extensions'),
    )
    peony_plugin_summary = 'yes'
  endif
endif
