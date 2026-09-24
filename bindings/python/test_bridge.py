"""Tests for the C ABI and the Python binding, using the scripted model (no Apple Intelligence needed).

    swift build --product OpenAppleModelsFFI
    python3 -m unittest discover -s bindings/python -v
"""

import asyncio
import decimal
import gc
import threading
import time
import unittest

import open_apple_models
from open_apple_models import Bridge, BridgeError, ToolError

GATE = {"type": "object", "properties": {"gate": {"type": "string"}}, "required": ["gate"]}


def scripted(*steps):
    return {"type": "scripted", "steps": list(steps)}


class BlockingTests(unittest.TestCase):
    def test_version_and_ping(self):
        with Bridge() as bridge:
            self.assertRegex(bridge.version, r"^\d+\.\d+\.\d+")
            self.assertEqual(bridge.call_blocking("ping"), {})

    def test_errors_are_typed(self):
        with Bridge() as bridge:
            with self.assertRaises(BridgeError) as caught:
                bridge.call_blocking("no/such/method")
            self.assertEqual(caught.exception.code, -32601)
            self.assertEqual(caught.exception.name, "method_not_found")

    def test_blocking_timeout_cancels_the_request(self):
        with Bridge() as bridge:
            session = bridge.call_blocking("session/create", {"model": scripted({"text": "late", "delayMs": 3000})})
            started = time.monotonic()
            with self.assertRaises(BridgeError) as caught:
                bridge.call_blocking("session/respond", {"session": session["session"], "prompt": "hi"}, timeout=0.2)
            self.assertEqual(caught.exception.code, -32024)
            self.assertLess(time.monotonic() - started, 2.0)


class LifetimeTests(unittest.TestCase):
    def test_call_blocking_after_close_raises(self):
        bridge = Bridge()
        bridge.close()
        with self.assertRaises(BridgeError) as caught:
            bridge.call_blocking("ping")
        self.assertEqual(caught.exception.name, "shut_down")

    def test_close_cancels_an_in_flight_blocking_call(self):
        bridge = Bridge()
        session = bridge.call_blocking("session/create", {"model": scripted({"text": "late", "delayMs": 5000})})
        errors = []

        def worker():
            try:
                bridge.call_blocking("session/respond", {"session": session["session"], "prompt": "hi"}, timeout=20)
            except BridgeError as error:
                errors.append(error)

        thread = threading.Thread(target=worker)
        thread.start()
        time.sleep(0.2)
        started = time.monotonic()
        bridge.close()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertEqual([error.name for error in errors], ["cancelled"])

    def test_bridge_moves_to_a_new_event_loop(self):
        bridge = Bridge()
        try:
            async def ping():
                return await bridge.request("ping")
            self.assertEqual(asyncio.run(ping()), {})
            self.assertEqual(asyncio.run(ping()), {})  # a second, new loop
        finally:
            bridge.close()

    def test_bridge_refuses_a_second_running_loop(self):
        bridge = Bridge()
        other = asyncio.new_event_loop()
        thread = threading.Thread(target=other.run_forever, daemon=True)
        thread.start()
        try:
            self.assertEqual(asyncio.run_coroutine_threadsafe(bridge.request("ping"), other).result(5), {})

            async def ping():
                return await bridge.request("ping")
            with self.assertRaises(RuntimeError):
                asyncio.run(ping())
        finally:
            other.call_soon_threadsafe(other.stop)
            thread.join(5)
            other.close()
            bridge.close()


class AsyncTests(unittest.IsolatedAsyncioTestCase):
    async def test_client_tool_round_trip_with_streaming(self):
        async with Bridge() as bridge:
            seen = []

            @bridge.tool("open_gate", "Open a gate.", GATE)
            async def open_gate(args, context):
                seen.append((args, context.session))
                await asyncio.sleep(0.01)
                return {"opened": True}

            session = await bridge.create_session(
                "You are a guard.", tools=["open_gate"], options={"toolChoice": "required"},
                model=scripted({"toolCalls": [{"name": "open_gate", "arguments": {"gate": "north"}}]},
                               {"template": "Result: {toolOutput}", "chunks": 4}))
            deltas, events = [], []
            reply = await session.respond("Open it", on_text=deltas.append, on_event=events.append)
            self.assertEqual(reply["text"], 'Result: {"opened":true}')
            self.assertEqual("".join(deltas), reply["text"])
            self.assertEqual(seen, [({"gate": "north"}, session.id)])
            self.assertEqual(reply["toolCalls"][0]["output"], {"opened": True})
            types = [event["type"] for event in events]
            self.assertIn("toolCallStarted", types)
            self.assertIn("toolCallCompleted", types)

    async def test_tool_errors_reach_the_model(self):
        async with Bridge() as bridge:
            @bridge.tool("open_gate", "Open a gate.", GATE)
            def open_gate(args):
                raise ToolError("The chain is jammed.")

            session = await bridge.create_session(
                tools=["open_gate"],
                model=scripted({"toolCalls": [{"name": "open_gate", "arguments": {"gate": "x"}}]}, {"template": "{toolOutput}"}))
            reply = await session.respond("Open it")
            self.assertTrue(reply["toolCalls"][0]["isError"])
            self.assertEqual(reply["text"], "Error: The chain is jammed.")

    async def test_tool_timeout_cancels_the_handler(self):
        async with Bridge() as bridge:
            cancelled = asyncio.Event()

            @bridge.tool("slow", "Slow tool.", None, timeout=0.2)
            async def slow(args):
                try:
                    await asyncio.sleep(5)
                except asyncio.CancelledError:
                    cancelled.set()
                    raise
                return "never"

            session = await bridge.create_session(
                tools=["slow"], model=scripted({"toolCalls": [{"name": "slow"}]}, {"template": "{toolOutput}"}))
            reply = await session.respond("go")
            self.assertTrue(reply["toolCalls"][0]["isError"])
            self.assertIn("timed out", reply["text"])
            await asyncio.wait_for(cancelled.wait(), 2)

    async def test_sessions_run_concurrently(self):
        async with Bridge() as bridge:
            a = await bridge.create_session(model=scripted({"text": "A", "delayMs": 300}))
            b = await bridge.create_session(model=scripted({"text": "B", "delayMs": 300}))
            started = time.monotonic()
            replies = await asyncio.gather(a.respond("go"), b.respond("go"))
            self.assertEqual([reply["text"] for reply in replies], ["A", "B"])
            self.assertLess(time.monotonic() - started, 0.55)

    async def test_cancel_and_model_errors(self):
        async with Bridge() as bridge:
            session = await bridge.create_session(model=scripted({"text": "late", "delayMs": 5000},
                                                                 {"error": "guardrail_violation"}))
            turn = asyncio.ensure_future(session.respond("wait"))
            await asyncio.sleep(0.05)
            self.assertEqual(await session.cancel(), 1)
            with self.assertRaises(BridgeError) as caught:
                await turn
            self.assertEqual(caught.exception.name, "cancelled")
            with self.assertRaises(BridgeError) as caught:
                await session.respond("unsafe")
            self.assertEqual((caught.exception.code, caught.exception.name), (-32002, "guardrail_violation"))

    async def test_transcript_round_trip(self):
        async with Bridge() as bridge:
            first = await bridge.create_session("You are Gorm.", model=scripted({"text": "Name's Gorm."}))
            await first.respond("Who are you?")
            saved = await first.transcript()
            second = await bridge.create_session("You are Gorm.", history=saved,
                                                 model=scripted({"template": "again: {prompt}"}))
            reply = await second.respond("And now?")
            self.assertEqual(reply["text"], "again: And now?")
            sessions = (await bridge.request("session/list"))["sessions"]
            self.assertEqual([entry["entries"] for entry in sessions], [2, 4])

    async def test_close_fails_pending_requests(self):
        bridge = Bridge()
        await bridge.__aenter__()
        session = await bridge.create_session(model=scripted({"text": "late", "delayMs": 5000}))
        turn = asyncio.ensure_future(session.respond("wait"))
        await asyncio.sleep(0.05)
        bridge.close()
        with self.assertRaises(BridgeError) as caught:
            await turn
        self.assertEqual(caught.exception.name, "shut_down")
        with self.assertRaises(BridgeError):
            bridge.notify("ping")

    async def test_values_that_are_not_strict_json(self):
        async with Bridge() as bridge:
            @bridge.tool("stats", "Stats.", None)
            def stats(args):
                return {"tags": {"iron"}, "price": decimal.Decimal("1.50"), "count": decimal.Decimal(3)}

            @bridge.tool("broken", "Broken.", None)
            def broken(args):
                return {"ratio": float("nan")}

            session = await bridge.create_session(tools=["stats", "broken"], model=scripted(
                {"toolCalls": [{"name": "stats"}]}, {"toolCalls": [{"name": "broken"}]}, {"text": "done"}))
            reply = await asyncio.wait_for(session.respond("go"), 5)
            converted, failed = reply["toolCalls"]
            self.assertEqual((converted["output"], converted["isError"]), ({"tags": ["iron"], "price": 1.5, "count": 3}, False))
            self.assertTrue(failed["isError"])
            self.assertIn("JSON", failed["output"])
            # Request params are checked before anything is sent or registered.
            with self.assertRaises(ValueError):
                await bridge.request("ping", {"x": float("inf")})
            with self.assertRaises(TypeError):
                await bridge.request("ping", {"x": object()})
            self.assertEqual(bridge._pending, {})
            self.assertEqual(await bridge.request("ping"), {})

    async def test_numpy_values_are_converted(self):
        try:
            import numpy
        except ImportError:
            self.skipTest("numpy is not installed")
        async with Bridge() as bridge:
            @bridge.tool("scores", "Scores.", None)
            def scores(args):
                return {"best": numpy.int64(7), "all": numpy.arange(3), "mean": numpy.float32(0.5)}

            session = await bridge.create_session(tools=["scores"], model=scripted(
                {"toolCalls": [{"name": "scores"}]}, {"text": "done"}))
            reply = await asyncio.wait_for(session.respond("go"), 5)
            self.assertEqual(reply["toolCalls"][0]["output"], {"best": 7, "all": [0, 1, 2], "mean": 0.5})

    async def test_blocking_call_events_carry_its_request_id(self):
        async with Bridge() as bridge:
            events = []
            bridge.on_notification("session/event", events.append)
            session = await bridge.create_session(model=scripted({"text": "hi there", "chunks": 2}))
            loop = asyncio.get_running_loop()
            reply = await loop.run_in_executor(None, lambda: bridge.call_blocking(
                "session/respond", {"session": session.id, "prompt": "x", "stream": True}))
            await asyncio.sleep(0.05)
            self.assertEqual(reply["text"], "hi there")
            ids = {event["requestId"] for event in events}
            self.assertEqual(len(ids), 1)
            self.assertTrue(next(iter(ids)).startswith("py-"))

    async def test_unclosed_bridge_stays_alive_until_closed(self):
        bridge = Bridge()
        await bridge.__aenter__()
        session = await bridge.create_session(model=scripted({"text": "late", "delayMs": 100}))
        # A response nobody waits for arrives after the last Python reference is gone.
        bridge.send_message({"jsonrpc": "2.0", "id": "orphan", "method": "session/respond",
                             "params": {"session": session.id, "prompt": "x"}})
        key = id(bridge)
        del bridge, session
        gc.collect()
        await asyncio.sleep(0.3)  # the callback fires into the still-registered bridge
        survivor = open_apple_models._live_bridges.get(key)
        self.assertIsNotNone(survivor)
        survivor.close()
        self.assertNotIn(key, open_apple_models._live_bridges)
        survivor.close()  # idempotent


def reply(line, emotion="neutral", options=("Buy one.", "Goodbye.")):
    """A structured NPC reply step for the scripted model."""
    return {"json": {"emotion": emotion, "line": line, "player_options": list(options), "ends_conversation": False}}


class GameTests(unittest.IsolatedAsyncioTestCase):
    async def test_npc_talk_with_client_tool_and_streaming(self):
        async with Bridge() as bridge:
            calls = []

            @bridge.tool("check_inventory", "Look up stock of an item.",
                         {"type": "object", "properties": {"item": {"type": "string"}}, "required": ["item"]})
            def check_inventory(args, context):
                calls.append((args["item"], context.npc))
                return {"stock": 3, "price_gold": 45}

            world = await bridge.create_world({"player": {"name": "Aria", "gold": 60}}, world="village")
            gorm = await bridge.create_npc(
                {"name": "Gorm", "role": "the village blacksmith"}, tools=["check_inventory"], world=world.id,
                options={"groundingTool": "check_inventory", "worldReadable": []}, npc="gorm",
                model=scripted({"toolCalls": [{"name": "check_inventory", "arguments": {"item": "iron sword"}}]},
                               reply("Three swords, lad.", "proud"), {"text": "Mind the forge."}))
            self.assertEqual(gorm.tools, ["check_inventory"])
            lines, emotions = [], []
            turn = await gorm.talk("Swords?", context="The shop is busy.", on_line=lines.append, on_emotion=emotions.append)
            self.assertEqual(turn["line"], "Three swords, lad.")
            self.assertEqual(turn["emotion"], "proud")
            self.assertEqual(turn["playerOptions"], ["Buy one.", "Goodbye."])
            self.assertEqual(lines[-1], turn["line"])
            self.assertEqual(emotions, ["proud"])
            self.assertEqual(calls, [("iron sword", "gorm")])
            self.assertEqual(turn["toolCalls"][0]["output"], {"stock": 3, "price_gold": 45})
            self.assertEqual(await gorm.bark("Night falls."), "Mind the forge.")
            npcs = await bridge.list_npcs()
            self.assertEqual([(entry["npc"], entry["turnCount"], entry["world"]) for entry in npcs], [("gorm", 1, "village")])

    async def test_npc_save_update_and_restore(self):
        async with Bridge() as bridge:
            gorm = await bridge.create_npc({"name": "Gorm"}, options={"replyFormat": "text"},
                                           model=scripted({"text": "[happy] Welcome!"}))
            self.assertEqual((await gorm.talk("Hi"))["emotion"], "happy")
            self.assertEqual(await gorm.update(memory={"relationship": 30}, persona={"role": "a smith"}), [])
            state = await gorm.state()
            self.assertEqual(state["memory"]["relationship"], 30)
            self.assertEqual(state["persona"]["role"], "a smith")
            self.assertEqual(state["options"]["replyFormat"], "text")
            await gorm.delete()
            restored = await bridge.restore_npc(state, model=scripted({"text": "[sad] Back again."}))
            self.assertEqual(restored.id, gorm.id)
            turn = await restored.talk("Hello again")
            self.assertEqual((turn["line"], turn["relationship"]), ("Back again.", 30))
            with self.assertRaises(BridgeError) as caught:
                await bridge.npc("nobody").talk("hi")
            self.assertEqual(caught.exception.name, "npc_not_found")

    async def test_decisions_and_content(self):
        async with Bridge() as bridge:
            decision = await bridge.decide(
                "The goblin has 3 HP left.", ["attack", {"id": "flee", "description": "Run away"}],
                actor={"name": "Snik", "personality": "Timid."}, context={"hp": 3},
                model=scripted({"json": {"reasoning": "Timid.", "choice": "flee", "confidence": 80}}))
            self.assertEqual((decision["optionID"], decision["confidence"], decision["isFallback"]), ("flee", 80, False))
            results = await bridge.decide_many(
                [{"situation": "A", "options": ["x", "y"]}, {"situation": "B", "options": ["x", "y"], "fallbackOptionID": "y"}],
                max_concurrency=1,
                model=scripted({"json": {"reasoning": "-", "choice": "x", "confidence": 50}}, {"error": "guardrail_violation"}))
            self.assertEqual([r["optionID"] for r in results], ["x", "y"])
            self.assertTrue(results[1]["isFallback"])
            item = await bridge.generate(
                "A cursed sword.",
                {"type": "object", "properties": {"name": {"type": "string"}, "damage": {"type": "integer"}},
                 "required": ["name", "damage"]},
                model=scripted({"json": {"damage": 45, "name": "Drowned Fang"}}))
            self.assertEqual(list(item.items()), [("name", "Drowned Fang"), ("damage", 45)])

    async def test_world_state_and_subscriptions(self):
        async with Bridge() as bridge:
            world = await bridge.create_world({"player": {"gold": 60}})
            changes = []
            subscription = await world.subscribe(changes.append, path="player")
            self.assertEqual(await world.set("player.gold", 45), 1)
            self.assertEqual(await world.get("player.gold"), 45)
            self.assertIsNone(await world.get("player.horse"))
            await world.merge({"quests": {"ring": "started"}})
            self.assertEqual(await world.remove("player.gold"), 45)
            self.assertEqual(await world.snapshot(), {"player": {}, "quests": {"ring": "started"}})
            await asyncio.sleep(0.05)
            self.assertEqual([(c["path"], c.get("oldValue"), c.get("newValue")) for c in changes],
                             [("player.gold", 60, 45), ("player.gold", 45, None)])
            await world.unsubscribe(subscription)
            await world.delete()
            with self.assertRaises(BridgeError) as caught:
                await world.get("player")
            self.assertEqual(caught.exception.name, "world_not_found")


if __name__ == "__main__":
    unittest.main()
