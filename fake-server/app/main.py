"""Faux serveur Mainsage : mêmes routes et messages que le vrai backend (BCK-01 à BCK-04)."""
import asyncio
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from . import replay
from .schemas import RecognitionIn, Session, Settings, Source, Status, Translation
from .state import State, now

DEFAULT_SCENARIO = Path(__file__).resolve().parent.parent / "scenarios" / "demo.json"


def create_app(scenario_path=None, speed: float = 1.0, autoplay: bool = True) -> FastAPI:
    state = State(
        video_url=os.getenv("MAINSAGE_VIDEO_URL", "http://localhost:8889/test"),
        whep_url=os.getenv("MAINSAGE_WHEP_URL", "http://localhost:8889/test/whep"),
    )
    scenario = replay.load_scenario(scenario_path or os.getenv("MAINSAGE_SCENARIO", DEFAULT_SCENARIO))

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        task = asyncio.create_task(replay.play(state, scenario, speed)) if autoplay else None
        yield
        if task:
            task.cancel()

    app = FastAPI(title="Mainsage - faux serveur", version="0.0.0", lifespan=lifespan)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    app.state.mainsage = state

    @app.get("/api/status", response_model=Status)
    def get_status():
        return Status(source=state.source, camera_connected=state.camera_connected,
                      engine_active=state.engine_active, latency_ms=state.latency_ms,
                      fps_after_selection=8.4, video_url=state.video_url, whep_url=state.whep_url)

    @app.get("/api/settings", response_model=Settings)
    def get_settings():
        return state.settings

    @app.put("/api/settings", response_model=Settings)
    def put_settings(settings: Settings):
        state.settings = settings
        return state.settings

    @app.get("/api/sessions", response_model=list[Session])
    def list_sessions():
        return list(state.sessions.values())

    @app.get("/api/sessions/current", response_model=Session)
    def current_session():
        if state.current_session_id is None:
            raise HTTPException(404, "Aucune session en cours")
        return state.sessions[state.current_session_id]

    @app.get("/api/sessions/{session_id}/recognitions", response_model=list[Translation])
    def session_recognitions(session_id: str):
        if session_id not in state.sessions:
            raise HTTPException(404, "Session inconnue")
        return state.recognitions[session_id]

    @app.put("/api/source", response_model=Source)
    def put_source(source: Source):
        state.source = source
        return source

    @app.post("/api/source/file", response_model=Source)
    async def upload_source_file(file: UploadFile):
        await file.read()  # le faux serveur ne l'utilise pas
        state.source = Source(kind="file", name=file.filename or "video")
        return state.source

    @app.post("/api/recognitions", response_model=Translation, status_code=201)
    async def post_recognition(data: RecognitionIn):
        """Point d'entrée du moteur ; utile pour injecter une traduction à la main."""
        tr = state.add_recognition(data)
        await state.broadcast("translation", tr)
        return tr

    @app.websocket("/ws")
    async def ws_endpoint(ws: WebSocket):
        await ws.accept()
        state.clients.add(ws)
        await ws.send_json({"type": "status", "data": get_status().model_dump(mode="json")})
        try:
            while True:
                await ws.receive_text()
        except WebSocketDisconnect:
            state.clients.discard(ws)

    web_dir = Path(os.getenv("MAINSAGE_WEB_DIR", Path(__file__).resolve().parents[2] / "web"))
    if web_dir.is_dir():
        app.mount("/", StaticFiles(directory=web_dir, html=True), name="web")
    return app


app = create_app()
