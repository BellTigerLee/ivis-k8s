import os
from dataclasses import dataclass, field
from pathlib import Path


class CredentialError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class Credentials:
    dsn: str = field(repr=False)
    ch_user: str = field(repr=False)
    ch_password: str = field(repr=False)


def secret_line(path: Path) -> str:
    try:
        value = path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        raise CredentialError("credentials_unavailable") from None
    if not value or "\n" in value or "\r" in value or "\x00" in value:
        raise CredentialError("credentials_invalid")
    return value


def load_credentials() -> Credentials:
    root = Path(os.environ.get("IVIS_HELM_CREDENTIAL_ROOT", "/credentials"))
    ch_user = secret_line(root / "clickhouse/username")
    ch_password = secret_line(root / "clickhouse/password")
    mode = os.environ.get("IVIS_HELM_PG_MODE", "dsn")
    pg = root / "postgres"
    if mode == "dsn":
        raw_dsn = secret_line(pg / "dsn")
    else:
        username = secret_line(pg / "username")
        password = secret_line(pg / "password")
    from psycopg.conninfo import conninfo_to_dict, make_conninfo
    from psycopg import ProgrammingError
    database = os.environ["IVIS_HELM_PG_DATABASE"]
    try:
        if mode == "dsn":
            if conninfo_to_dict(raw_dsn).get("dbname") != database:
                raise CredentialError("postgres_database_mismatch")
            dsn = make_conninfo(raw_dsn)
        elif mode == "userPassword":
            dsn = make_conninfo(
                host=os.environ["IVIS_HELM_PG_HOST"],
                port=os.environ["IVIS_HELM_PG_PORT"],
                dbname=database, user=username, password=password,
                sslmode=os.environ["IVIS_HELM_PG_SSLMODE"],
            )
        else:
            raise CredentialError("postgres_credentials_mode_invalid")
    except ProgrammingError:
        raise CredentialError("postgres_connection_settings_invalid") from None
    return Credentials(dsn, ch_user, ch_password)


def configure_server(credentials: Credentials) -> None:
    if os.environ.get("IVIS_INVENTORY_ENABLED") == "1" and any(
        os.environ.get(key, "CHANGE_ME") == "CHANGE_ME"
        for key in ("IVIS_INVENTORY_CLUSTER_NAME", "IVIS_INVENTORY_CLUSTER_UID")
    ):
        raise CredentialError("inventory_cluster_identity_required")
    os.environ["IVIS_POSTGRES_DSN"] = credentials.dsn
    os.environ["IVIS_CLICKHOUSE_USER"] = credentials.ch_user
    os.environ["IVIS_CLICKHOUSE_PASSWORD"] = credentials.ch_password
    os.environ["IVIS_SIGNALS_CH_USER"] = credentials.ch_user
    os.environ.pop("IVIS_POSTGRES_DSN_FILE", None)
    os.environ.pop("IVIS_SIGNALS_PG_DSN_FILE", None)
    root = Path(os.environ.get("IVIS_HELM_CREDENTIAL_ROOT", "/credentials"))
    os.environ["IVIS_SIGNALS_CH_PASSWORD_FILE"] = str(root / "clickhouse/password")
