"""
title: Remove Image Background
author: docker-compose-homelab
version: 0.2.0
license: MIT
# Block scalar, not a plain one. Open WebUI parses this docstring as YAML and a
# bare ": " or " #" anywhere below would either error out or truncate the value
# -- either way the function silently never loads. Inside | both are literal.
description: |
  Strip the background from an image attached to the chat, using the rembg service.

  Open WebUI tools (OpenAPI) only take text arguments, so a tool cannot see an
  image dragged into the chat. A pipe function can. Open WebUI passes the
  conversation to it, and the image in the last user message arrives as a
  base64 data URI.

  Usage: attach an image and say "remove the background". Works with Indonesian
  too -- the prompt is only used as the caption.
"""

import base64
import re

import requests

# Service name on the ai-net docker network. Matches the service name in
# rembg/docker-compose.yml.
#
# Path is /api/remove, NOT /api/v1/remove -- the v1 prefix 404s on
# danielgatis/rembg:2.0.85. Confirmed against the running container's
# /openapi.json, which lists exactly one route: "/api/remove".
REMBG_URL = "http://rembg:7000/api/remove"
MODEL = "u2net"  # swap to isnet-general-use for hair/fur edges

# A pasted image is a data URI; a generated one may be a URL. Both show up.
DATA_URI = re.compile(r"data:image/[\w.+-]+;base64,(?P<b64>[A-Za-z0-9+/=\s]+)")


def _first_image(messages: list) -> str | None:
    """Newest user message wins, and within it the newest image."""
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        images = message.get("images") or []
        if images:
            return images[0]
        match = DATA_URI.search(message.get("content") or "")
        if match:
            return f"data:image/png;base64,{match.group('b64')}"
    return None


class Pipe:
    def pipes(self) -> list:
        return [
            {
                "type": "filter",  # runs on the input, not the model's reply
                "id": "remove_background",
                "name": "Remove Image Background",
            }
        ]

    def pipe(self, body: dict, __user__=None, **kwargs) -> dict:
        messages = body.get("messages", [])
        image = _first_image(messages)

        if not image:
            # Nothing to do. Returning the input unchanged keeps the model
            # answering normally instead of seeing a tool error.
            return {"messages": messages}

        raw = base64.b64decode(image.split(",", 1)[1])

        response = requests.post(
            REMBG_URL,
            files={"file": ("input.png", raw, "image/png")},
            data={"model": MODEL},
            timeout=120,
        )
        response.raise_for_status()

        out = base64.b64encode(response.content).decode()
        caption = (messages[-1].get("content") or "").split("data:image")[0].strip()
        result = f"{caption}\n![result](data:image/png;base64,{out})"

        # Appended to the existing last user message, not sent as a second one.
        # Two user messages back to back is rejected by most chat backends, and
        # Open WebUI renders markdown in the user bubble either way.
        messages[-1]["content"] = result
        return {"messages": messages}
