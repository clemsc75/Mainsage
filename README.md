# Mainsage

Traduction de la langue des signes française (LSF) en français écrit, en direct.
Mini-projet de BTS CIEL 2e année, par Iuliana Pelipetcaia (interface web) et Clément Simonin (acquisition, moteur, backend).

Le cahier des charges fait foi pour les exigences (ACQ, MOT, BCK, WEB) et le format JSON.

## Contenu

| Dossier | Rôle |
|---|---|
| `fake-server/` | Faux backend FastAPI (REST + WebSocket, traductions rejouées) pour développer l'interface sans moteur ni caméra |
| `tools/webrtc-test/` | Banc d'essai de l'horodatage WebRTC dans le navigateur |

## Méthode

TDD (pytest), Conventional Commits (`feat(web): ...`), SemVer (0.y.z jusqu'à la v1), GitFlow : `main`, `develop`, `feature/<sujet>`.
