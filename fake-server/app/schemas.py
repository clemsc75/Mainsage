"""Contrat JSON de Mainsage (cahier des charges §5). Repris tel quel par le vrai backend."""
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Mode = Literal["word", "phrase"]


class Candidate(BaseModel):
    label: str
    p: float = Field(ge=0, le=1)


class RecognitionIn(BaseModel):
    """Message moteur -> backend (HTTP POST /api/recognitions), BCK-01."""
    session_id: str
    timestamp: datetime
    start_frame: int
    end_frame: int
    frame_timestamp: datetime | None = None  # horodatage de l'image où le signe se termine
    top: Candidate
    alternatives: list[Candidate] = Field(default_factory=list)
    model_version: str


class Translation(RecognitionIn):
    """Traduction diffusée au frontend (WebSocket) et listée dans l'historique."""
    id: int
    frame_timestamp: datetime
    recognized: bool = True  # False : « signe non reconnu » (MOT-04)
    mode: Mode = "word"


class Correction(BaseModel):
    """Mode phrase : un mot précédent est corrigé (BCK-05)."""
    session_id: str
    translation_id: int
    old_label: str
    new_label: str
    sentence: str
    timestamp: datetime


class SentenceFinal(BaseModel):
    session_id: str
    sentence: str
    frame_timestamp: datetime


class GestureState(BaseModel):
    state: Literal["signing", "waiting"]
    frame_timestamp: datetime


class PidSettings(BaseModel):
    kp: float = 0.6
    ki: float = 0.05
    kd: float = 0.1
    deadband_px: int = 40


class Settings(BaseModel):
    diff_threshold_pct: float = Field(default=2.0, ge=0, le=100)
    confidence_threshold: float = Field(default=0.5, ge=0, le=1)
    mode: Mode = "word"
    pid: PidSettings = PidSettings()


class Source(BaseModel):
    kind: Literal["camera", "file"] = "camera"
    name: str = "Wansview Q5"


class Status(BaseModel):
    source: Source
    camera_connected: bool
    engine_active: bool
    latency_ms: int
    fps_after_selection: float
    video_url: str  # page/flux WebRTC (MediaMTX) ; whep_url pour un lecteur maison
    whep_url: str


class Session(BaseModel):
    id: str
    started_at: datetime
    ended_at: datetime | None = None
    mode: Mode = "word"
