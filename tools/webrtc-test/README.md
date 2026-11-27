# Test de l'horodatage WebRTC

But : savoir si le navigateur donne un repère fiable de l'image affichée (WEB-02, tolérance ±300 ms).

1. Lancer MediaMTX avec `mediamtx.yml` (binaire ou `docker run --rm --network=host -v $PWD/mediamtx.yml:/mediamtx.yml bluenviron/mediamtx`).
2. `./publish.sh` : publie une vidéo 9:16 dont chaque image porte son numéro en binaire.
3. `python3 serve.py`, puis ouvrir `http://localhost:8000/index.html` et cliquer sur « Lire ».
4. La page lit le numéro d'image à l'écran et le compare au `rtpTimestamp` de `requestVideoFrameCallback`.

À tester sur Chrome et Firefox (Firefox ne fournit pas toujours `rtpTimestamp`). Noter les résultats dans `RESULTATS.md`.
Si le verdict est « trop instable » : plan B du cahier des charges (le backend renvoie les images analysées numérotées).
