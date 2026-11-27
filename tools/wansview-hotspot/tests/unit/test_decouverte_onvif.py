"""Tests de la sonde ONVIF, uniquement sur la boucle locale (127.0.0.1)."""

import contextlib
import importlib.util
import io
import socket
import threading
import unittest
from pathlib import Path

OUTIL = Path(__file__).resolve().parents[2] / "outils" / "decouverte-onvif.py"


def charger():
    spec = importlib.util.spec_from_file_location("decouverte_onvif", OUTIL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reponse(adresses: str, portees: str = "onvif://www.onvif.org/name/Cam") -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
        "<s:Body><d:ProbeMatches><d:ProbeMatch>"
        f"<d:Scopes>{portees}</d:Scopes><d:XAddrs>{adresses}</d:XAddrs>"
        "</d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>"
    ).encode()


class FausseCamera:
    """Répond à la première sonde reçue avec les messages fournis."""

    def __init__(self, *messages: bytes):
        self.messages = messages
        self.sonde = b""
        self.prise = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.prise.bind(("127.0.0.1", 0))
        self.prise.settimeout(3)
        self.port = self.prise.getsockname()[1]
        self.fil = threading.Thread(target=self._servir, daemon=True)

    def _servir(self):
        with contextlib.suppress(OSError):
            self.sonde, emetteur = self.prise.recvfrom(65535)
            for message in self.messages:
                self.prise.sendto(message, emetteur)

    def __enter__(self):
        self.fil.start()
        return self

    def __exit__(self, *_):
        self.fil.join(timeout=3)
        self.prise.close()


class TestSonde(unittest.TestCase):
    def setUp(self):
        self.outil = charger()

    def lancer(self, *arguments):
        sortie, erreurs = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(sortie), contextlib.redirect_stderr(erreurs):
            try:
                code = self.outil.main(list(arguments))
            except SystemExit as fin:
                code = fin.code
        return code, sortie.getvalue(), erreurs.getvalue()

    def sonder(self, camera):
        return self.lancer(
            "--source", "127.0.0.1", "--cible", "127.0.0.1",
            "--port", str(camera.port), "--duree", "0.5",
        )

    def test_reponse_affichee(self):
        with FausseCamera(reponse("http://10.42.0.10/onvif/device_service")) as camera:
            code, sortie, _ = self.sonder(camera)
        self.assertEqual(0, code)
        self.assertIn("127.0.0.1", sortie)
        self.assertIn("http://10.42.0.10/onvif/device_service", sortie)

    def test_sonde_conforme_et_unique(self):
        with FausseCamera() as premiere:
            self.sonder(premiere)
        with FausseCamera() as seconde:
            self.sonder(seconde)
        self.assertIn(b"Probe", premiere.sonde)
        self.assertIn(b"NetworkVideoTransmitter", premiere.sonde)
        self.assertIn(b"urn:uuid:", premiere.sonde)
        self.assertNotEqual(premiere.sonde, seconde.sonde)

    def test_aucune_reponse(self):
        with FausseCamera() as camera:
            code, sortie, _ = self.sonder(camera)
        self.assertEqual(1, code)
        self.assertIn("Aucune réponse", sortie)

    def test_caracteres_dangereux_retires(self):
        adresses = "http://a/‮&#x9b;31mrouge\nsuite"
        with FausseCamera(reponse(adresses)) as camera:
            code, sortie, _ = self.sonder(camera)
        self.assertEqual(0, code)
        self.assertNotIn("‮", sortie)
        self.assertNotIn("\x9b", sortie)
        self.assertNotIn("\x1b", sortie)

    def test_valeur_tres_longue_tronquee(self):
        with FausseCamera(reponse("http://a/" + "x" * 5000)) as camera:
            _, sortie, _ = self.sonder(camera)
        self.assertLess(len(sortie), 1000)

    def test_doctype_refuse(self):
        piege = (
            b'<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "secret">]>'
            b"<x><XAddrs>&a;</XAddrs></x>"
        )
        with FausseCamera(piege) as camera:
            code, sortie, erreurs = self.sonder(camera)
        self.assertEqual(1, code)
        self.assertNotIn("secret", sortie)
        self.assertIn("ignorée", erreurs)

    def test_doctype_en_utf16_refuse(self):
        piege = (
            '<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE x [<!ENTITY a "secret">]>'
            "<x><XAddrs>&a;</XAddrs></x>"
        ).encode("utf-16")
        with FausseCamera(piege) as camera:
            code, sortie, _ = self.sonder(camera)
        self.assertEqual(1, code)
        self.assertNotIn("secret", sortie)

    def test_reponse_illisible_ignoree(self):
        with FausseCamera(b"\x00\x01pas du xml", reponse("http://ok/")) as camera:
            code, sortie, _ = self.sonder(camera)
        self.assertEqual(0, code)
        self.assertIn("http://ok/", sortie)

    def test_arguments_invalides(self):
        for arguments in (
            [],
            ["--source", "nimporte"],
            ["--source", "127.0.0.1", "--port", "0"],
            ["--source", "127.0.0.1", "--port", "70000"],
            ["--source", "127.0.0.1", "--duree", "-1"],
            ["--source", "127.0.0.1", "--duree", "nan"],
            ["--source", "127.0.0.1", "--cible", "exemple"],
        ):
            with self.subTest(arguments=arguments):
                self.assertEqual(2, self.lancer(*arguments)[0])

    def test_adresse_source_absente_du_pc(self):
        code, _, erreurs = self.lancer("--source", "192.0.2.1", "--duree", "0.2")
        self.assertEqual(2, code)
        self.assertIn("192.0.2.1", erreurs)


if __name__ == "__main__":
    unittest.main()
