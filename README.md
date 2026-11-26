# Mainsage

Traduction de la langue des signes française (LSF) en français écrit, en direct.
Mini-projet de BTS CIEL 2e année, par Iuliana Pelipetcaia (interface web) et Clément Simonin (acquisition, moteur, backend).

Le cahier des charges fait foi pour les exigences (ACQ, MOT, BCK, WEB) et le format JSON.

## Contenu

| Dossier | Rôle |
|---|---|
| `docs/` | Cahier des charges et guide d'aide du faux serveur (PDF) |
| `fake-server/` | Faux backend FastAPI (REST + WebSocket, traductions rejouées) pour développer l'interface sans moteur ni caméra |
| `tools/webrtc-test/` | Banc d'essai de l'horodatage WebRTC dans le navigateur |
| `tools/wansview-hotspot/` | Point d'accès Wi-Fi 2,4 GHz temporaire et isolé pour la caméra Wansview |

## Méthode

TDD (pytest), Conventional Commits (`feat(web): ...`), SemVer (0.y.z jusqu'à la v1), GitFlow : `main`, `develop`, `feature/<sujet>`.
