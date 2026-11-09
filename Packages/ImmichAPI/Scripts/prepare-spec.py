#!/usr/bin/env python3
"""Derive the generator input from Immich's OpenAPI spec (docs/DESIGN.md, D1).

The spec in api/ is never modified. This writes a patched copy next to the
generator config with one change: POST /sync/stream declares its JSON Lines
body, so the generated client exposes it as a streaming HTTPBody.

Usage: prepare-spec.py <input-spec> <output-spec>
"""

import json
import sys

# The server sends application/jsonlines+json. The generator would treat any
# "+json" type as a single JSON document, so the patch declares */* instead:
# that is generated as a raw HTTPBody and matches whatever the server sends.
SYNC_STREAM_CONTENT_TYPE = "*/*"


def patch(spec: dict) -> dict:
    response = spec["paths"]["/sync/stream"]["post"]["responses"]["200"]
    if "content" in response:
        raise SystemExit("/sync/stream already declares content; review whether the patch is still needed")
    response["content"] = {
        SYNC_STREAM_CONTENT_TYPE: {"schema": {"type": "string", "format": "binary"}}
    }
    return spec


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, destination = sys.argv[1], sys.argv[2]
    with open(source, encoding="utf-8") as f:
        spec = json.load(f)
    with open(destination, "w", encoding="utf-8") as f:
        json.dump(patch(spec), f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
