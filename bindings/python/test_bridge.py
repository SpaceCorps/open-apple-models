"""Tests for the C ABI and the Python binding, using the scripted model (no Apple Intelligence needed).

    swift build --product OpenAppleModelsFFI
    python3 -m unittest discover -s bindings/python -v
"""

import asyncio
import time
import unittest

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


if __name__ == "__main__":
    unittest.main()
