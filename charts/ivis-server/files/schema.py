import os
from pathlib import Path
import re
from typing import Final
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from credentials import Credentials


PG_CORE: Final = ("pg-001-core.sql", "pg-002-seed.sql")
PG_NATIVE: Final = "pg-003-execution.sql"
PG_SIGNALS: Final = "pg-004-kumec-signals.sql"
CH_TABLES: Final = ("ivis_kumec_history", "ivis_signal_event", "ivis_signal_sample")
TRANSACTION_LINES: Final = re.compile(r"^\s*(BEGIN|COMMIT)\s*;\s*$", re.I | re.M)


class SchemaError(RuntimeError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SchemaError("clickhouse_redirect_refused")


def prepare_postgres(root: Path, credentials: Credentials) -> None:
    import psycopg
    names = list(PG_CORE)
    if os.environ.get("IVIS_INVENTORY_ENABLED") == "1":
        names.append(PG_NATIVE)
    if os.environ.get("IVIS_SIGNALS_ENABLED") == "1":
        names.append(PG_SIGNALS)
    try:
        with psycopg.connect(credentials.dsn, connect_timeout=10, autocommit=True,
                             application_name="ivis-helm-schema") as connection:
            with connection.transaction():
                connection.execute("SET LOCAL search_path TO public, pg_catalog")
                connection.execute("SET LOCAL lock_timeout = '5s'")
                connection.execute("SET LOCAL statement_timeout = '60s'")
                for name in names:
                    text = TRANSACTION_LINES.sub("", (root / name).read_text(encoding="utf-8"))
                    connection.execute(text, prepare=False)
    except psycopg.Error as error:
        state = error.sqlstate or "connection"
        raise SchemaError("postgres_failed_" + state) from None
    print("ivis schema: postgres ready", flush=True)


def prepare_clickhouse(root: Path, credentials: Credentials) -> None:
    if os.environ.get("IVIS_SIGNALS_ENABLED") != "1":
        return
    database = os.environ["IVIS_SIGNALS_CH_DATABASE"]
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,62}", database):
        raise SchemaError("clickhouse_database_invalid")
    if database.lower() in {"system", "information_schema"}:
        raise SchemaError("clickhouse_system_database_refused")
    url = os.environ["IVIS_SIGNALS_CH_URL"]
    parsed = urlsplit(url)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment or parsed.path not in {"", "/"}):
        raise SchemaError("clickhouse_url_invalid")
    opener = build_opener(ProxyHandler({}), NoRedirect())
    params = urlencode({"database": database, "wait_end_of_query": 1, "max_execution_time": 60,
                        "max_threads": 1, "max_memory_usage": 268435456})
    for table in CH_TABLES:
        query = (root / ("ch-" + table + ".sql")).read_text(encoding="utf-8")
        query = query.replace("__DATABASE__", database)
        request = Request(url.rstrip("/") + "/?" + params, data=query.encode(), method="POST",
                          headers={"X-ClickHouse-User": credentials.ch_user,
                                   "X-ClickHouse-Key": credentials.ch_password})
        try:
            with opener.open(request, timeout=65) as response:
                if len(response.read(65537)) > 65536:
                    raise SchemaError("clickhouse_response_limit")
        except HTTPError as error:
            raise SchemaError("clickhouse_http_" + str(error.code)) from None
        except (URLError, OSError, ValueError):
            raise SchemaError("clickhouse_request_failed") from None
    print("ivis schema: clickhouse ready", flush=True)


def prepare_schema(credentials: Credentials) -> None:
    root = Path(os.environ.get("IVIS_HELM_SQL_ROOT", "/opt/sql"))
    prepare_postgres(root, credentials)
    prepare_clickhouse(root, credentials)
