# Faux serveur Mainsage

Se comporte comme le vrai backend : mêmes routes, mêmes messages WebSocket. Les données sont en mémoire.

```bash
cd fake-server
python3 -m venv .venv
source .venv/bin/activate          # Windows : .venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload      # serveur sur http://localhost:8000
pytest                             # tests
```

Documentation OpenAPI : http://localhost:8000/docs (interface Swagger), http://localhost:8000/redoc, schéma brut : http://localhost:8000/openapi.json.

## Contrat

REST (JSON) :

- `GET /api/status` : source, caméra, moteur, latence, `video_url` et `whep_url` (flux WebRTC de MediaMTX)
- `GET|PUT /api/settings` : seuil de différence, seuil de confiance, mode `word`/`phrase`, gains PID
- `PUT /api/source`, `POST /api/source/file` : choix de la source (caméra ou fichier envoyé)
- `GET /api/sessions`, `GET /api/sessions/current`, `GET /api/sessions/{id}/recognitions` : historique
- `POST /api/recognitions` : entrée du moteur (format du cahier §5) ; le faux serveur la diffuse aussi

WebSocket `/ws` : messages `{"type": ..., "data": {...}}` de type `status`, `translation`, `correction`, `gesture_state`, `sentence_final`.

Une `translation` porte `frame_timestamp` (ISO UTC) : l'horodatage de l'image où le signe se termine. Le frontend l'affiche quand la vidéo atteint cet instant, plus le délai de synchronisation réglable (WEB-02).
Une traduction avec `recognized: false` correspond à « signe non reconnu ».

## Scénario

`scenarios/demo.json` : événements à `at` secondes, reçus `delay_ms` plus tard (latence du moteur). Variables d'environnement : `MAINSAGE_SCENARIO`, `MAINSAGE_VIDEO_URL`, `MAINSAGE_WHEP_URL`, `MAINSAGE_WEB_DIR` (dossier `web/` servi à la racine s'il existe).
