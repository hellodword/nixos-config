umask 077
state="$HOME/.local/state/wrangler"
mkdir -p -- "$state"
chmod 700 -- "$state"

args=(
  --unshare-all --unshare-user --share-net --disable-userns
  --die-with-parent --new-session --cap-drop ALL
  --clearenv --hostname wrangler
  --tmpfs / --proc /proc --dev /dev --tmpfs /tmp --tmpfs /work
  --dir /nix/store --dir /home/wrangler/.config
  --bind "$state" /home/wrangler/.config/.wrangler
  --ro-bind /etc/resolv.conf /etc/resolv.conf
  --ro-bind /etc/hosts /etc/hosts
  --ro-bind '@caBundle@' /etc/ssl/certs/ca-certificates.crt
  --ro-bind '@nsswitch@' /etc/nsswitch.conf
  --symlink '@shell@' /bin/sh
  --symlink '@shell@' /bin/bash
  --setenv HOME /home/wrangler
  --setenv XDG_CONFIG_HOME /home/wrangler/.config
  --setenv XDG_CACHE_HOME /tmp/cache
  --setenv TMPDIR /tmp
  --setenv PATH '@runtimePath@'
  --setenv LANG C.UTF-8
  --setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
  --setenv WRANGLER_SEND_METRICS false
  --chdir /work
)

# Only the application's runtime closure is visible in the sandbox store.
while IFS= read -r path; do
  args+=(--ro-bind "$path" "$path")
done < '@closure@'

exec {passwd_fd}< <(printf 'wrangler:x:%s:%s:Wrangler:/home/wrangler:/bin/sh\n' "$(id -u)" "$(id -g)")
exec {group_fd}< <(printf 'wrangler:x:%s:\n' "$(id -g)")
args+=(--ro-bind-data "$passwd_fd" /etc/passwd --ro-bind-data "$group_fd" /etc/group)

# Authentication commands can run from the repository root without exposing it.
if [[ -f wrangler.json ]]; then
  if [[ -L .wrangler ]]; then
    printf '%s\n' 'The Worker .wrangler workspace must be a directory, not a symlink.' >&2
    exit 1
  fi
  mkdir -p -- .wrangler
  args+=(--ro-bind "$(pwd -P)" /work --tmpfs /work/.wrangler)
fi

for variable in TERM COLORTERM NO_COLOR CI HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  if [[ -v $variable ]]; then
    args+=(--setenv "$variable" "${!variable}")
  fi
done

exec bwrap "${args[@]}" --remount-ro / -- '@wrangler@' "$@"
