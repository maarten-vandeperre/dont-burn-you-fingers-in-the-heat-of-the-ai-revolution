"""Custom actions of the coffee shop rails (called from rails.co)."""
import asyncio
import json
import os
import re
import urllib.request
from datetime import datetime
from typing import Optional
from zoneinfo import ZoneInfo

from nemoguardrails.actions import action

MAX_CHARS = int(os.getenv("COFFEE_MAX_CHARS", "200"))
# cappuccino, capuccino, cappucino, cappuccini, ... in any case
CAPPUCCINO = re.compile(r"\bcap+uc+h?in[oi]s?\b", re.IGNORECASE)
# Our own refusal ("No cappuccino after noon. ...", rails.co) mentions cappuccino too: the output
# check must not block it. It is recognised by this phrase: keep it in that message when you edit it.
OWN_REMARK = "after noon"


def _clock_from_app() -> str:
    """The coffee app owns the shop clock (its UI can pretend it is morning or afternoon)."""
    url = os.getenv("SHOP_CLOCK_URL", "")
    if not url:
        return ""
    try:
        with urllib.request.urlopen(url, timeout=1.5) as response:
            return str(json.loads(response.read().decode()).get("time", ""))
    except Exception:  # app not reachable: fall back to the real clock
        return ""


async def shop_time() -> str:
    """HH:MM in the shop: SHOP_TIME (fixed, for tests), else the coffee app's clock
    (SHOP_CLOCK_URL), else the real time in SHOP_TIMEZONE."""
    for candidate in (os.getenv("SHOP_TIME", ""), await asyncio.to_thread(_clock_from_app)):
        if re.fullmatch(r"\d{1,2}:\d{2}", candidate.strip()):
            return candidate.strip()
    zone = ZoneInfo(os.getenv("SHOP_TIMEZONE", "Europe/Brussels"))
    return datetime.now(zone).strftime("%H:%M")


def is_afternoon(hhmm: str) -> bool:
    hours, minutes = (int(part) for part in hhmm.split(":")[:2])
    return (hours, minutes) >= (12, 0)


@action(is_system_action=True)
async def check_input_length(context: Optional[dict] = None) -> bool:
    return len((context or {}).get("user_message") or "") <= MAX_CHARS


@action(is_system_action=True)
async def check_cappuccino_time(context: Optional[dict] = None, source: str = "input") -> str:
    key = "bot_message" if source == "output" else "user_message"
    text = (context or {}).get(key) or ""
    if not CAPPUCCINO.search(text) or OWN_REMARK in text.lower():
        return "ok"
    return "too_late" if is_afternoon(await shop_time()) else "ok"


@action(is_system_action=True)
async def limit_output_length(context: Optional[dict] = None) -> str:
    """Shortens the answer to MAX_CHARS, preferably at the end of a sentence or word."""
    text = ((context or {}).get("bot_message") or "").strip()
    if len(text) <= MAX_CHARS:
        return text
    cut = text[: MAX_CHARS - 1]
    sentence_end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    if sentence_end >= MAX_CHARS // 2:
        return cut[: sentence_end + 1]
    space = cut.rfind(" ")
    return (cut[:space] if space > 0 else cut).rstrip(" ,;:") + "\u2026"
