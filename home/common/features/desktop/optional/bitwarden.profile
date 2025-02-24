ignore no3d
ignore dbus-user none

# https://github.com/netblue30/firejail/issues/3982#issuecomment-778480897
whitelist ${HOME}/.mozilla/firefox/profiles.ini
read-only ${HOME}/.mozilla/firefox/profiles.ini

noblacklist ${HOME}/.config/BraveSoftware/Brave-Browser
noblacklist ${HOME}/.config/chromium
noblacklist ${HOME}/.mozilla

dbus-system none
dbus-user filter

dbus-user.talk org.freedesktop.secrets

dbus-user.talk org.fcitx.Fcitx5
dbus-user.talk org.freedesktop.portal.Fcitx
dbus-user.talk org.fcitx.Fcitx.*
dbus-user.talk org.freedesktop.portal.IBus

# xdg-open URL
# https://github.com/netblue30/firejail/issues/6275#issuecomment-2000577631
dbus-user.own org.chromium.*
dbus-user.own org.mozilla.firefox.*
# private-bin awk,basename,cut,env,grep,head,realpath,sed,tr,uname,xdg-mime
# private-bin chromium,chromium-browser,elinks,epiphany,firefox,google-chrome,iceweasel,konqueror,links,links2,lynx,mozilla,seamonkey,w3m,www-browser,x-www-browser

noblacklist ${HOME}/.config/Bitwarden CLI
mkdir ${HOME}/.config/Bitwarden CLI
whitelist ${HOME}/.config/Bitwarden CLI
include bitwarden.profile
