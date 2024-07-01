ignore dbus-user none

dbus-system none
dbus-user filter

dbus-user.talk org.freedesktop.secrets

dbus-user.talk org.fcitx.Fcitx5
dbus-user.talk org.freedesktop.portal.Fcitx
dbus-user.talk org.fcitx.Fcitx.*
dbus-user.talk org.freedesktop.portal.IBus

dbus-user.talk org.freedesktop.Notifications
dbus-user.talk org.kde.StatusNotifierItem
dbus-user.talk org.kde.StatusNotifierWatcher
?ALLOW_TRAY: dbus-user.talk org.kde.StatusNotifierWatcher

include electron-common.profile
include electron-common-hardened.inc.profile

noblacklist ${HOME}/.config/anytype
whitelist ${HOME}/.config/anytype
