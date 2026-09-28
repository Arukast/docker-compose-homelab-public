"""
title: Remove Image Background
author: docker-compose-homelab
version: 0.3.0
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
MODEL = "isnet-general-use"  # hair/fur / white-on-white edges; u2net for hard-edged products

# A pasted image is a data URI; a generated one may be a URL. Both show up.
DATA_URI = re.compile(r"data:image/[\w.+-]+;base64,(?P<b64>[A-Za-z0-9+/=\s]+)")


def _text(content) -> str:
    """content is a plain string, or a list of parts. Both are real here."""
    if isinstance(content, str):
        return content
    return "".join(
        p.get("text", "") for p in content or [] if isinstance(p, dict) and p.get("type") == "text"
    )


def _first_image(messages: list) -> str | None:
    """Newest user message wins, and within it the newest image.

    Two shapes reach us. Open WebUI's own format puts attachments in a
    top-level "images" list. When a vision-capable model is selected, content
    is an OpenAI parts list and the image is an image_url part. Both are data
    URIs. Older builds inlined a bare data URI in a string, so that is still
    checked -- but only after isinstance, or re.search explodes on a list.
    """
    for message in reversed(messages):
        if message.get("role") != "user":
            continue

        if images := message.get("images"):
            return images[0]

        content = message.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "image_url":
                    url = part["image_url"]
                    return url["url"] if isinstance(url, dict) else url
            continue

        if match := DATA_URI.search(content or ""):
            return f"data:image/png;base64,{match.group('b64')}"
    return None


class Pipe:
    def pipes(self) -> list:
        return [
            {
                "id": "remove_background",
                "name": "Remove Image Background",
            }
        ]

    def pipe(self, body: dict, __user__=None, **kwargs) -> str:
        messages = body.get("messages", [])
        image = _first_image(messages)

        # Pipe runs are invisible in the UI, so log what actually happened.
        # "Found no image" here means the attachment never reached us, which is
        # a very different bug from rembg failing.
        print(f"[remove_background] model={body.get('model')} messages={len(messages)} image={'yes' if image else 'NO'}")
        if not image:
            # Nothing to remove. A one-line note is better than silence: the
            # user learns the model can't see their image before they wonder
            # why nothing happened.
            return "No image found in the message. Attach one, then send it again."

        raw = base64.b64decode(image.split(",", 1)[1])

        response = requests.post(
            REMBG_URL,
            files={"file": ("input.png", raw, "image/png")},
            data={"model": MODEL},
            timeout=120,
        )
        print(f"[remove_background] rembg {response.status_code} {len(response.content)} bytes")
        response.raise_for_status()

        out = base64.b64encode(response.content).decode()

        # Must be a plain string. The backend only converts a str into a chat
        # message (see get_message_content in open_webui/functions.py); a dict
        # is returned to the client as the raw response body and never renders.
        return f"Background removed ({MODEL}).\n\n![result](data:image/png;base64,{out})"
