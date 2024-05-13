set -e
set -x

[ -f "$RCLONE_CONFIG_FILE" ]
[ -f "$ENV_FILE" ]
[ -d "$WORK_DIR" ]

. "$ENV_FILE"
[ -n "$TAILSCALE_S3_REMOTE_NAME" ]
[ -n "$TAILSCALE_S3_BUCKET" ]

tailscale status --json | jq '[recurse | objects | with_entries(select(.key == "PublicKey")) | .[]] | sort' > "$WORK_DIR/temp.verifier.json"
jq -e . "$WORK_DIR/temp.verifier.json"
if [ "$(cat "$WORK_DIR/verifier.json" || true)" != "$(cat "$WORK_DIR/temp.verifier.json")" ]; then
  rclone --config "$RCLONE_CONFIG_FILE" --contimeout=3m --timeout=10m --checksum copyto "$WORK_DIR/temp.verifier.json" $TAILSCALE_S3_REMOTE_NAME:$TAILSCALE_S3_BUCKET/verifier.json
  mv "$WORK_DIR/temp.verifier.json" "$WORK_DIR/verifier.json"
fi
