"""
Fügt Projekt-Unterverzeichnisse zum sys.path hinzu,
damit Tests lib/ und scripts/ direkt importieren können.
"""
import sys
from pathlib import Path

PROJECT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT / "lib"))
sys.path.insert(0, str(PROJECT / "scripts"))
