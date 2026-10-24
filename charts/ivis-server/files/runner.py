import os
import sys

from credentials import CredentialError, configure_server, load_credentials
from schema import SchemaError, prepare_schema


def main() -> int:
    try:
        credentials = load_credentials()
        if sys.argv[1:] == ["schema"]:
            prepare_schema(credentials)
        elif sys.argv[1:] == ["server"]:
            configure_server(credentials)
            os.execvp("ivis-server", ["ivis-server"])
        else:
            raise CredentialError("mode_must_be_server_or_schema")
    except (CredentialError, SchemaError) as error:
        print("ivis schema: " + str(error), file=sys.stderr)
        return 1
    except (OSError, KeyError, ValueError, ImportError):
        print("ivis schema: runtime_or_settings_unavailable", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
