set -e
set -x

[ -f "$RCLONE_CONFIG_FILE" ]
[ -f "$ENV_FILE" ]
[ -d "$WORK_DIR" ]

. "$ENV_FILE"
[ -n "$TAILSCALE_S3_REMOTE_NAME" ]
[ -n "$TAILSCALE_S3_BUCKET" ]

tailscale status --json | jq '[recurse | objects | with_entries(select(.key == "PublicKey")) | .[]] | sort' > "$WORK_DIR/temp.nodes.json"
jq -e . "$WORK_DIR/temp.nodes.json"
if [ "$(cat "$WORK_DIR/nodes.json" || true)" != "$(cat "$WORK_DIR/temp.nodes.json")" ]; then
  rclone --config "$RCLONE_CONFIG_FILE" --contimeout=3m --timeout=10m --checksum copyto "$WORK_DIR/temp.nodes.json" $TAILSCALE_S3_REMOTE_NAME:$TAILSCALE_S3_BUCKET/nodes.json
  mv "$WORK_DIR/temp.nodes.json" "$WORK_DIR/nodes.json"
fi
