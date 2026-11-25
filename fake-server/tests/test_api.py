"""Tests du contrat d'API. Chaque test cite l'exigence visée."""
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.main import create_app

NOW = datetime(2026, 11, 24, 21, 30, 12, tzinfo=timezone.utc).isoformat()
MSG = {  # exemple du cahier des charges §5
    "session_id": "2026-11-24-a", "timestamp": NOW, "start_frame": 1840, "end_frame": 1872,
    "top": {"label": "bonjour", "p": 0.71},
    "alternatives": [{"label": "merci", "p": 0.18}, {"label": "au revoir", "p": 0.06}],
    "model_version": "0.3.0",
}


@pytest.fixture
def client():
    with TestClient(create_app(autoplay=False)) as c:
        yield c


def test_status_donne_etat_et_video(client):  # WEB-04
    r = client.get("/api/status").json()
    assert r["camera_connected"] and r["engine_active"] and r["video_url"] and r["whep_url"]


def test_reglages_modifiables(client):  # BCK-04
    s = client.get("/api/settings").json()
    s["mode"], s["diff_threshold_pct"] = "phrase", 5
    assert client.put("/api/settings", json=s).json()["mode"] == "phrase"
    assert client.get("/api/settings").json()["diff_threshold_pct"] == 5


def test_reglage_invalide_refuse(client):  # BCK-04
    s = client.get("/api/settings").json()
    s["confidence_threshold"] = 3
    assert client.put("/api/settings", json=s).status_code == 422


def test_message_moteur_stocke_et_historique(client):  # BCK-01, BCK-02
    r = client.post("/api/recognitions", json=MSG)
    assert r.status_code == 201 and r.json()["id"] == 1
    assert [s["id"] for s in client.get("/api/sessions").json()] == ["2026-11-24-a"]
    hist = client.get("/api/sessions/2026-11-24-a/recognitions").json()
    assert hist[0]["top"]["label"] == "bonjour" and len(hist[0]["alternatives"]) == 2
    assert client.get("/api/sessions/current").json()["id"] == "2026-11-24-a"


def test_message_moteur_invalide(client):  # BCK-01
    bad = dict(MSG, top={"label": "x", "p": 2})
    assert client.post("/api/recognitions", json=bad).status_code == 422


def test_session_inconnue(client):  # BCK-02
    assert client.get("/api/sessions/nope/recognitions").status_code == 404
    assert client.get("/api/sessions/current").status_code == 404


def test_websocket_pousse_la_traduction_avec_horodatage_image(client):  # BCK-03, WEB-02
    with client.websocket_connect("/ws") as ws:
        assert ws.receive_json()["type"] == "status"
        client.post("/api/recognitions", json=dict(MSG, frame_timestamp=NOW))
        msg = ws.receive_json()
    assert msg["type"] == "translation"
    assert msg["data"]["frame_timestamp"].startswith("2026-11-24T21:30:12")
    assert msg["data"]["top"]["label"] == "bonjour"


def test_choix_de_la_source(client):  # WEB-04
    assert client.put("/api/source", json={"kind": "camera", "name": "Wansview Q5"}).status_code == 200
    r = client.post("/api/source/file", files={"file": ("essai.mp4", b"x", "video/mp4")})
    assert r.json() == {"kind": "file", "name": "essai.mp4"}
    assert client.get("/api/status").json()["source"]["kind"] == "file"
