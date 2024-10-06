ignore dbus-user none

mkdir ${HOME}/.config/anytype
noblacklist ${HOME}/.config/anytype
whitelist ${HOME}/.config/anytype

# https://github.com/netblue30/firejail/issues/3982#issuecomment-778480897
whitelist ${HOME}/.mozilla/firefox/profiles.ini
read-only ${HOME}/.mozilla/firefox/profiles.ini

# https://github.com/anyproto/anytype-ts/blob/e9bdf53c82e6f7686a42c082072f8a05bc74673b/electron/js/lib/installNativeMessagingHost.js#L152-L155
noblacklist ${HOME}/.config/BraveSoftware/Brave-Browser
mkdir ${HOME}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts
mkfile ${HOME}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.anytype.desktop.json
whitelist ${HOME}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.anytype.desktop.json

noblacklist ${HOME}/.config/chromium
mkdir ${HOME}/.config/chromium/NativeMessagingHosts
mkfile ${HOME}/.config/chromium/NativeMessagingHosts/com.anytype.desktop.json
whitelist ${HOME}/.config/chromium/NativeMessagingHosts/com.anytype.desktop.json

noblacklist ${HOME}/.mozilla
mkdir ${HOME}/.mozilla/native-messaging-hosts
mkfile ${HOME}/.mozilla/native-messaging-hosts/com.anytype.desktop.json
whitelist ${HOME}/.mozilla/native-messaging-hosts/com.anytype.desktop.json

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

# xdg-open URL
# https://github.com/netblue30/firejail/issues/6275#issuecomment-2000577631
dbus-user.own org.chromium.*
dbus-user.own org.mozilla.firefox.*
# private-bin awk,basename,cut,env,grep,head,realpath,sed,tr,uname,xdg-mime
# private-bin chromium,chromium-browser,elinks,epiphany,firefox,google-chrome,iceweasel,konqueror,links,links2,lynx,mozilla,seamonkey,w3m,www-browser,x-www-browser

include electron-common.profile
include electron-common-hardened.inc.profile
