"""open-apple-models from Python: an NPC that uses game tools the host executes.

    swift build -c release --product OpenAppleModelsFFI
    python3 bindings/python/example.py          # scripted model: no Apple Intelligence needed
    python3 bindings/python/example.py --live   # the on-device model

What it shows:
  1. initialize / model availability (also via the synchronous blocking helper),
  2. a session whose tools run in Python (the model decides, the host executes),
  3. streaming text, a forced first tool call, and a structured decision,
  4. a tool error the model recovers from,
  5. saving the transcript and restoring it into a new session.
"""

import asyncio
import json
import sys

from open_apple_models import Bridge, BridgeError, ToolError

LIVE = "--live" in sys.argv

INSTRUCTIONS = ("You are Gorm, a grumpy blacksmith in a fantasy game. Use your tools to check facts "
                "before answering. Reply in at most two sentences.")

STOCK = {"iron sword": {"stock": 3, "price_gold": 45}, "shield": {"stock": 0, "price_gold": 30}}


def scripted(*steps):
    """A deterministic model for CI and engine development (see docs/PROTOCOL.md)."""
    return {"type": "scripted", "steps": list(steps)}


async def main() -> None:
    async with Bridge() as bridge:
        # -- tools the game executes -------------------------------------------------------
        @bridge.tool("check_inventory", "Look up stock and price (in gold) of an item.",
                     {"type": "object", "properties": {"item": {"type": "string", "description": "Item name"}},
                      "required": ["item"]})
        async def check_inventory(args, context):
            await asyncio.sleep(0.05)  # e.g. wait for the game thread
            item = args["item"].strip().lower()
            if item not in STOCK and item.endswith("s") and item[:-1] in STOCK:
                item = item[:-1]  # "iron swords" -> "iron sword"
            if item not in STOCK:
                raise ToolError("No item called '{}' in this shop.".format(item))
            return {"item": item, **STOCK[item]}

        @bridge.tool("wave", "Play the wave animation at someone.",
                     {"type": "object", "properties": {"target": {"type": "string"}}, "required": ["target"]})
        def wave(args):
            print("   [game] Gorm waves at {}".format(args["target"]))
            return "Waved."

        info = await bridge.initialize("example.py")
        print("bridge", info["server"]["version"], "- model available:", info["model"]["available"],
              "- context", info["model"]["contextSize"], "tokens")
        print("blocking helper:", bridge.call_blocking("ping"))

        # -- 1. a grounded answer with a forced first tool call ---------------------------
        model = "system" if LIVE else scripted(
            {"toolCalls": [{"name": "check_inventory", "arguments": {"item": "iron sword"}}]},
            {"template": "Three iron swords, 45 gold each. Don't haggle. ({toolOutput})"},
            {"toolCalls": [{"name": "check_inventory", "arguments": {"item": "mithril axe"}}]},
            {"template": "Never heard of it. ({toolOutput})"},
            {"json": {"reasoning": "30 gold is below my price of 45.", "choice": "haggle"}},
        )
        gorm = await bridge.create_session(INSTRUCTIONS, tools=["check_inventory", "wave"], model=model)
        print("\nPlayer: Got any iron swords? How much?")
        print("Gorm:   ", end="", flush=True)
        reply = await gorm.respond("Got any iron swords? How much?", toolChoice={"tool": "check_inventory"},
                                   on_text=lambda delta: print(delta, end="", flush=True))
        print()
        for record in reply["toolCalls"]:
            print("   tool:", record["call"]["name"], json.dumps(record["call"]["arguments"]), "->", json.dumps(record["output"]))

        # -- 2. a tool error the model sees --------------------------------------------------
        print("\nPlayer: Do you sell mithril axes?")
        reply = await gorm.respond("Do you sell mithril axes?", toolChoice="required")
        print("Gorm:  ", reply["text"])
        print("   tool error reported to the model:", [r["isError"] for r in reply["toolCalls"]])

        # -- 3. a structured decision ------------------------------------------------------
        decision = await gorm.respond(
            "A customer offers 30 gold for an iron sword. Decide.",
            schema={"type": "object", "properties": {
                "reasoning": {"type": "string", "description": "One short sentence"},
                "choice": {"type": "string", "enum": ["sell", "refuse", "haggle"]}},
                "required": ["reasoning", "choice"]},
            toolChoice="none")
        print("\nDecision:", json.dumps(decision["structured"]))

        # -- 4. save and restore -------------------------------------------------------------
        saved = await gorm.transcript()
        restored_model = "system" if LIVE else scripted({"template": "You asked me that already: {prompt}"})
        again = await bridge.create_session(INSTRUCTIONS, tools=["check_inventory"], model=restored_model, history=saved)
        reply = await again.respond("What did I first ask you about?", toolChoice="none")
        print("\nRestored Gorm:", reply["text"])

        # -- errors are typed ------------------------------------------------------------------
        try:
            await bridge.request("session/respond", {"session": "nobody", "prompt": "hi"})
        except BridgeError as error:
            print("\nExpected error:", error.code, error.name)


if __name__ == "__main__":
    asyncio.run(main())
