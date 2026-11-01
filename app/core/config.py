from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    app_name: str = "GarbageTrack"
    debug: bool = False
    api_v1_prefix: str = "/api/v1"
    mongodb_uri: str = "mongodb://localhost:27017"
    mongodb_db_name: str = "garbagetrack"
    jwt_secret_key: SecretStr = SecretStr("dev-secret-change-me-use-a-long-random-value")
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 7
    password_hash_rounds: int = 12
    admin_email: str | None = None
    admin_password: str | None = None
    cors_origins: list[str] = []
    routing_cache_dir: str = "var/route-cache"
    routing_timeout_s: float = 30.0
    # Optional self-hosted OSRM server (e.g. http://localhost:5000). When set,
    # road geometry is requested from OSRM first, then OSMnx, then straight lines.
    osrm_base_url: str | None = None

    @field_validator("jwt_secret_key")
    @classmethod
    def check_secret_length(cls, value: SecretStr) -> SecretStr:
        if len(value.get_secret_value().encode("utf-8")) < 32:
            raise ValueError("jwt_secret_key must be at least 32 bytes (RFC 7518, HS256)")
        return value


settings = Settings()
