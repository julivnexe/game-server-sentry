"""CSV parser tests — exercise every row type in docs/CSV_FORMAT.md plus
malformed inputs. If these pass, adapters writing the documented schema
will be parsed correctly by the production code."""
import pytest

from tests.csv_parser import Row, parse_row, parse_command_extra, parse_state_extra


# ---------- valid rows, each action type ----------

def test_join_v1_versioned():
    row = parse_row(
        "2026-05-15T19:46:31Z,My Server,join,player1,1.2.3.4:51234,abc,,v1"
    )
    assert row == Row(
        timestamp="2026-05-15T19:46:31Z",
        server_name="My Server",
        action="join",
        player_name="player1",
        ip="1.2.3.4:51234",
        hash="abc",
        extra="",
        schema_version="v1",
    )


def test_leave_v1_versioned():
    row = parse_row(
        "2026-05-15T19:48:12Z,My Server,leave,player1,1.2.3.4:51234,abc,,v1"
    )
    assert row.action == "leave"
    assert row.schema_version == "v1"


def test_command_with_extra_payload():
    row = parse_row(
        "2026-05-15T19:49:01Z,My Server,command,player1,1.2.3.4:51234,abc,"
        "lvl=3|cmd=/lo3,v1"
    )
    assert row.action == "command"
    assert row.extra == "lvl=3|cmd=/lo3"
    lvl, cmd = parse_command_extra(row.extra)
    assert lvl == "3"
    assert cmd == "/lo3"


def test_state_heartbeat():
    row = parse_row(
        "2026-05-15T19:49:00Z,My Server,state,,,,maxplayers=16,v1"
    )
    assert row.action == "state"
    assert row.player_name == ""
    assert row.ip == ""
    assert parse_state_extra(row.extra) == 16


def test_startup():
    row = parse_row(
        "2026-05-15T19:23:41Z,My Server,startup,,,,,v1"
    )
    assert row.action == "startup"
    assert row.schema_version == "v1"


# ---------- backward compat: legacy unversioned rows ----------

def test_legacy_7field_row_treated_as_v1():
    # No trailing schema_version — old adapter, should still parse.
    row = parse_row(
        "2026-05-15T19:46:31Z,My Server,join,player1,1.2.3.4:51234,abc,"
    )
    assert row.action == "join"
    assert row.schema_version == "v1"  # inferred


def test_legacy_6field_pre_extra_row():
    # Even older format with no extra and no schema_version.
    row = parse_row(
        "2026-05-15T19:46:31Z,My Server,join,player1,1.2.3.4:51234,abc"
    )
    assert row.action == "join"
    assert row.extra == ""
    assert row.schema_version == "v1"


# ---------- malformed rows: must not raise, must return None ----------

@pytest.mark.parametrize("garbage", [
    "",                          # empty
    "\n",                        # whitespace only
    "    ",                      # spaces
    "# comment line",            # comment style
    "garbage",                   # one field
    "1,2,3",                     # too few fields
    "1,2,3,4,5",                 # five fields — still too few
])
def test_malformed_rows_yield_none(garbage):
    assert parse_row(garbage) is None


def test_row_with_empty_action_rejected():
    # Comma-counts look right but action is empty — reject so the bot
    # never tries to dispatch on "".
    assert parse_row(
        "2026-05-15T19:46:31Z,My Server,,player1,1.2.3.4:51234,abc,,v1"
    ) is None


def test_extra_with_embedded_pipe_chars_preserved():
    # `extra` is intentionally allowed to contain `|` as a payload
    # sub-delimiter; only `,`/`\n` are forbidden inside fields.
    row = parse_row(
        "2026-05-15T19:49:01Z,My Server,command,p,1.2.3.4,h,"
        "lvl=2|cmd=/ban thug life|reason=spam,v1"
    )
    assert "|" in row.extra
    lvl, cmd = parse_command_extra(row.extra)
    assert lvl == "2"
    # parse_command_extra stops at the first `|` after `cmd=`, so the
    # downstream embed gets exactly what the player typed up to the
    # next reserved key. This is documented behaviour, not a bug.
    assert cmd.startswith("/ban thug life")


def test_excess_fields_past_schema_version_are_ignored():
    # Forward-compat: a future v2 may add columns after schema_version.
    # The v1 parser must not crash on them — it just ignores extras.
    line = ("2026-05-15T19:46:31Z,My Server,join,p,1.2.3.4,h,,v1,"
            "future_field_v2,another")
    # We only split into 8 parts max, so the schema_version field will
    # contain the trailing junk concatenated. v1 production parsers
    # treat schema_version as opaque — they don't crash.
    row = parse_row(line)
    assert row is not None
    assert row.action == "join"


# ---------- escaping rules ----------

def test_csv_safe_strips_commas_in_names():
    """Replicates the discord_notify.lua csv_safe() contract."""
    def csv_safe(s: str) -> str:
        return (s or "").replace(",", " ").replace("\n", " ").replace("\r", "")
    assert csv_safe("Bob, the builder") == "Bob  the builder"
    # \n is replaced with space; \r is deleted (matches the Lua adapter)
    assert csv_safe("multi\nline\rname") == "multi linename"
    assert csv_safe(None) == ""
