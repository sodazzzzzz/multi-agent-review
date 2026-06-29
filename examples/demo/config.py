"""Demo app config with intentionally planted issues (NOT for production)."""

DEBUG = True  # planted: debug enabled in a shipped config
ADMIN_PASSWORD = "admin123"  # planted: hardcoded credential in source
ALLOWED_HOSTS = ["*"]  # planted: wildcard host allowlist


def database_url():
    # planted: credentials embedded in the connection string
    return "postgres://admin:admin123@db.internal:5432/payments"
