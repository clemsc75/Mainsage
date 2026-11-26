"""État en mémoire du faux serveur et diffusion WebSocket."""
import asyncio
from datetime import datetime, timezone

from fastapi import WebSocket

from .schemas import RecognitionIn, Session, Settings, Source, Translation


def now() -> datetime:
    return datetime.now(timezone.utc)


class State:
    def __init__(self, video_url: str, whep_url: str):
        self.settings = Settings()
        self.source = Source()
        self.video_url = video_url
        self.whep_url = whep_url
        self.sessions: dict[str, Session] = {}
        self.recognitions: dict[str, list[Translation]] = {}
        self.current_session_id: str | None = None
        self.clients: set[WebSocket] = set()
        self.next_id = 1
        self.camera_connected = True
        self.engine_active = True
        self.latency_ms = 900

    def ensure_session(self, session_id: str) -> Session:
        if session_id not in self.sessions:
            self.sessions[session_id] = Session(id=session_id, started_at=now(), mode=self.settings.mode)
            self.recognitions[session_id] = []
        self.current_session_id = session_id
        return self.sessions[session_id]

    def add_recognition(self, data: RecognitionIn, recognized: bool = True, mode=None) -> Translation:
        self.ensure_session(data.session_id)
        tr = Translation(**data.model_dump(exclude={"frame_timestamp"}), id=self.next_id,
                         frame_timestamp=data.frame_timestamp or data.timestamp,
                         recognized=recognized, mode=mode or self.settings.mode)
        self.next_id += 1
        self.recognitions[data.session_id].append(tr)
        return tr

    async def broadcast(self, type_: str, data) -> None:
        payload = {"type": type_, "data": data.model_dump(mode="json") if hasattr(data, "model_dump") else data}
        for ws in list(self.clients):
            try:
                await ws.send_json(payload)
            except Exception:
                self.clients.discard(ws)
