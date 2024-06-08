# bwrap

```sh
bwrap \
--unshare-all \
--new-session \
--symlink usr/lib /lib \
--symlink usr/lib64 /lib64 \
--symlink usr/bin /bin \
--symlink usr/bin /sbin \
--ro-bind /usr/lib /usr/lib \
--ro-bind /usr/lib64 /usr/lib64 \
--ro-bind /usr/bin /usr/bin \
--dev /dev \
echo hello


bwrap \
--unshare-all \
--new-session \
--symlink usr/lib /lib \
--symlink usr/lib64 /lib64 \
--symlink usr/bin /bin \
--symlink usr/bin /sbin \
--ro-bind /usr/lib /usr/lib \
--ro-bind /usr/lib64 /usr/lib64 \
--ro-bind /usr/bin /usr/bin \
--dev /dev \
--ro-bind /etc/resolv.conf /etc/resolv.conf \
--ro-bind /usr/share/ca-certificates /usr/share/ca-certificates \
--ro-bind /etc/ssl /etc/ssl \
--ro-bind /etc/ca-certificates /etc/ca-certificates \
--proc /proc \
--tmpfs /tmp \
--share-net \
--setenv HOME /home/example \
--bind $PWD /home/example \
curl ip.sb -v -o test.txt


bwrap \
--unshare-all \
--new-session \
--symlink usr/lib /lib \
--symlink usr/lib64 /lib64 \
--symlink usr/bin /bin \
--symlink usr/bin /sbin \
--ro-bind /usr/lib /usr/lib \
--ro-bind /usr/lib64 /usr/lib64 \
--ro-bind /usr/bin /usr/bin \
--dev /dev \
--ro-bind /etc/resolv.conf /etc/resolv.conf \
--ro-bind /usr/share/ca-certificates /usr/share/ca-certificates \
--ro-bind /etc/ssl /etc/ssl \
--ro-bind /etc/ca-certificates /etc/ca-certificates \
--proc /proc \
--tmpfs /tmp \
--share-net \
--setenv HOME /home/example \
--bind $PWD /home/example \
sh test.sh
```
