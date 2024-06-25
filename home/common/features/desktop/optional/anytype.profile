dbus-system none
ignore dbus-user none
dbus-user filter
dbus-user.talk org.freedesktop.secrets

include electron-common.profile
include electron-common-hardened.inc.profile

noblacklist ${HOME}/.config/anytype
whitelist ${HOME}/.config/anytype
