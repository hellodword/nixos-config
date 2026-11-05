#!/usr/bin/env python3
"""Decode DNS collector JSON or journalctl -o json into complete DNS messages."""
import argparse
import base64
import json
import sys

import dns.exception
import dns.message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", help="include only this QNAME (case insensitive)")
    args = parser.parse_args()
    for line in sys.stdin:
        try:
            if not line.lstrip().startswith("{"):
                continue
            event = json.loads(line)
            if "MESSAGE" in event:
                if not event["MESSAGE"].lstrip().startswith("{"):
                    continue
                event = json.loads(event["MESSAGE"])
            payload = event.get("extracted", {}).get("dns_payload")
            if not payload:
                continue
            message = dns.message.from_wire(base64.b64decode(payload))
            if args.name and (not message.question or message.question[0].name.to_text().rstrip('.').lower() != args.name.rstrip('.').lower()):
                continue
            print(json.dumps({"time": event["dnstap"].get("timestamp-rfc3339ns"),
                              "identity": event["dnstap"].get("identity"),
                              "policy": json.loads(event["dnstap"].get("extra", "{}")),
                              "dns": message.to_text()}, ensure_ascii=False), flush=True)
        except (ValueError, KeyError, TypeError, dns.exception.DNSException) as error:
            print(f"Cannot decode DNS log entry: {type(error).__name__}", file=sys.stderr)


if __name__ == "__main__":
    main()
