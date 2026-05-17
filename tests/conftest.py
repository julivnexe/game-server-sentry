"""pytest configuration / shared fixtures.

The bot modules under observability/* import heavy third-party packages
(prometheus_client, requests) and run module-level side effects
(parse_servers from env, etc). The tests below avoid importing the
modules wholesale; instead they exercise either pure functions that
can be cherry-picked, or replicate the contract under test against
the live spec in docs/CSV_FORMAT.md.

This keeps `pytest` runnable on a clean checkout without docker or
network access.
"""
import os
import sys
import pathlib

# Make repo root importable so tests can `from tests.helpers import ...`
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))


def pytest_configure(config):
    # Stub env so any module-level os.environ.get reads have sane values
    # if a test does decide to import a bot module.
    os.environ.setdefault("DISCORD_WEBHOOK", "https://example.invalid/test")
    os.environ.setdefault("HALO_SERVERS", "2312:Test Server:4")
    os.environ.setdefault("PLAYER_LOG", "/tmp/halo_test_players.log")
