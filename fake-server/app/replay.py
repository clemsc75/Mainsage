"""Rejoue un scénario : chaque traduction arrive `delay_ms` après la fin du signe
et porte l'horodatage de l'image où le signe se termine (frame_timestamp)."""
import asyncio
import json
from datetime import timedelta
from pathlib import Path

from .schemas import Candidate, Correction, GestureState, RecognitionIn, SentenceFinal
from .state import State, now

MODEL_VERSION = "0.0.0-fake"


def load_scenario(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


async def play(state: State, scenario: dict, speed: float = 1.0) -> None:
    """Joue le scénario une fois (en boucle si scenario["loop"])."""
    while True:
        t0 = now()
        tasks = [asyncio.create_task(_emit(state, scenario, ev, t0, speed)) for ev in scenario["events"]]
        await asyncio.gather(*tasks)
        if not scenario.get("loop"):
            return
        await asyncio.sleep(2 / speed)


async def _emit(state: State, scenario: dict, ev: dict, t0, speed: float) -> None:
    delay = ev.get("delay_ms", 0) / 1000
    await asyncio.sleep((ev["at"] + delay) / speed)
    frame_ts = t0 + timedelta(seconds=ev["at"] / speed)  # image d'origine
    sid = scenario.get("session_id", "demo")
    state.ensure_session(sid)
    kind = ev["type"]
    if kind == "gesture":
        await state.broadcast("gesture_state", GestureState(state=ev["state"], frame_timestamp=frame_ts))
    elif kind == "translation":
        top = Candidate(label=ev["top"][0], p=ev["top"][1])
        alts = [Candidate(label=a[0], p=a[1]) for a in ev.get("alternatives", [])]
        fps = 25
        end_frame = int(((frame_ts - t0).total_seconds()) * fps)
        data = RecognitionIn(session_id=sid, timestamp=now(), frame_timestamp=frame_ts,
                             start_frame=max(0, end_frame - 30), end_frame=end_frame,
                             top=top, alternatives=alts, model_version=MODEL_VERSION)
        tr = state.add_recognition(data, recognized=ev.get("recognized", True), mode=ev.get("mode"))
        await state.broadcast("translation", tr)
    elif kind == "correction":
        last = state.recognitions[sid][-2] if len(state.recognitions[sid]) > 1 else state.recognitions[sid][-1]
        await state.broadcast("correction", Correction(
            session_id=sid, translation_id=last.id, old_label=ev["old_label"],
            new_label=ev["new_label"], sentence=ev["sentence"], timestamp=now()))
    elif kind == "sentence_final":
        await state.broadcast("sentence_final", SentenceFinal(
            session_id=sid, sentence=ev["sentence"], frame_timestamp=frame_ts))
