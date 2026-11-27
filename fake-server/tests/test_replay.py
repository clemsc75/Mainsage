"""Rejeu du scénario : horodatage de l'image d'origine et types de messages."""
import asyncio

from app import replay
from app.state import State

SCENARIO = {"session_id": "t", "events": [
    {"at": 0.0, "type": "gesture", "state": "signing"},
    {"at": 0.1, "delay_ms": 50, "type": "translation", "top": ["bonjour", 0.7], "alternatives": [["merci", 0.2]]},
    {"at": 0.1, "delay_ms": 60, "type": "translation", "recognized": False, "top": ["signe non reconnu", 0.2], "alternatives": []},
]}


class FakeWS:
    def __init__(self):
        self.msgs = []

    async def send_json(self, m):
        self.msgs.append(m)


def test_rejeu_envoie_traductions_en_retard_sur_l_image():  # WEB-02, MOT-04
    state = State("v", "w")
    ws = FakeWS()
    state.clients.add(ws)
    asyncio.run(replay.play(state, SCENARIO))
    types = [m["type"] for m in ws.msgs]
    assert types == ["gesture_state", "translation", "translation"]
    first, second = ws.msgs[1]["data"], ws.msgs[2]["data"]
    assert first["recognized"] and not second["recognized"]
    # la traduction arrive après l'image où le signe se termine
    assert first["timestamp"] > first["frame_timestamp"]
