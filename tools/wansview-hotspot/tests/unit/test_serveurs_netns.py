"""Tests des serveurs et clients du test d'isolation, sur la boucle locale."""

import socket
import subprocess
import sys
import unittest
from pathlib import Path

OUTIL = Path(__file__).resolve().parents[1] / "netns" / "serveurs.py"


def port_libre(genre) -> int:
    with socket.socket(socket.AF_INET, genre) as prise:
        prise.bind(("127.0.0.1", 0))
        return prise.getsockname()[1]


def client(*arguments) -> int:
    commande = [sys.executable, "-B", str(OUTIL), *map(str, arguments)]
    return subprocess.run(commande, capture_output=True, timeout=10).returncode


class TestServeurs(unittest.TestCase):
    def setUp(self):
        self.tcp = port_libre(socket.SOCK_STREAM)
        self.udp = port_libre(socket.SOCK_DGRAM)
        self.serveur = subprocess.Popen(
            [sys.executable, "-B", str(OUTIL), "serveur",
             "--tcp", f"127.0.0.1:{self.tcp}", "--udp", f"127.0.0.1:{self.udp}"],
            stdout=subprocess.PIPE, text=True,
        )
        self.assertEqual("PRET", self.serveur.stdout.readline().strip())

    def tearDown(self):
        self.serveur.kill()
        self.serveur.wait()
        self.serveur.stdout.close()

    def test_tcp_joignable(self):
        self.assertEqual(0, client("tcp", "127.0.0.1", self.tcp))

    def test_udp_joignable_avec_port_source(self):
        source = port_libre(socket.SOCK_DGRAM)
        self.assertEqual(0, client("udp", "127.0.0.1", self.udp, "--port-source", source))

    def test_port_ferme(self):
        self.assertEqual(1, client("tcp", "127.0.0.1", port_libre(socket.SOCK_STREAM)))
        self.assertEqual(1, client("udp", "127.0.0.1", port_libre(socket.SOCK_DGRAM)))


if __name__ == "__main__":
    unittest.main()
