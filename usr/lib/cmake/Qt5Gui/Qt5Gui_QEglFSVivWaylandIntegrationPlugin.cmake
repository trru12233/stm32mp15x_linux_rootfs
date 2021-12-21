
add_library(Qt5::QEglFSVivWaylandIntegrationPlugin MODULE IMPORTED)

_populate_Gui_plugin_properties(QEglFSVivWaylandIntegrationPlugin RELEASE "egldeviceintegrations/libqeglfs-viv-wl-integration.so")

list(APPEND Qt5Gui_PLUGINS Qt5::QEglFSVivWaylandIntegrationPlugin)
