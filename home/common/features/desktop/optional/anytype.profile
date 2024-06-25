dbus-system none
ignore dbus-user none
dbus-user filter
dbus-user.talk org.freedesktop.secrets

include electron.profile
# error at https://github.com/netblue30/firejail/blob/0.9.72/etc/profile-a-l/electron-hardened.inc.profile#L10
# fixed in the future
include chromium-common-hardened.inc.profile

noblacklist ${HOME}/.config/anytype
whitelist ${HOME}/.config/anytype
