import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


def _normalize_database_url(database_url: str) -> str:
    """
    Railway/Postgres часто задают DATABASE_URL в виде postgresql://...
    Для SQLAlchemy async используем postgresql+asyncpg://...
    """
    if database_url.startswith("postgresql://"):
        return "postgresql+asyncpg://" + database_url[len("postgresql://") :]
    if database_url.startswith("postgres://"):
        return "postgresql+asyncpg://" + database_url[len("postgres://") :]
    return database_url


DATABASE_URL = os.getenv("DATABASE_URL")
if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is not set")

ASYNC_DATABASE_URL = _normalize_database_url(DATABASE_URL)

engine = create_async_engine(
    ASYNC_DATABASE_URL,
    echo=False,
    future=True,
)

AsyncSessionMaker = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


@asynccontextmanager
async def session_scope() -> AsyncIterator[AsyncSession]:
    async with AsyncSessionMaker() as session:
        yield session


async def init_db(*, drop: bool = False) -> None:
    """
    Только для локальной отладки. В проде — Alembic.
    """
    import farm.models  # noqa: F401

    async with engine.begin() as conn:
        if drop:
            await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)


async def ensure_migrations_applied() -> None:
    """
    Fail-fast: миграции Alembic применены.
    """
    expected_revision = (os.getenv("ALEMBIC_EXPECTED_REVISION") or "").strip()

    async with engine.begin() as conn:
        exists = await conn.scalar(
            text(
                """
                SELECT EXISTS (
                  SELECT 1
                  FROM information_schema.tables
                  WHERE table_schema = 'public'
                    AND table_name = 'alembic_version'
                )
                """
            )
        )
        if not exists:
            raise RuntimeError(
                "Database is not migrated: missing table alembic_version. "
                "Run `alembic upgrade head` before starting services."
            )

        current_revision = await conn.scalar(
            text("SELECT version_num FROM alembic_version LIMIT 1")
        )
        if not current_revision:
            raise RuntimeError(
                "Database migration state is empty. Run `alembic upgrade head`."
            )

        if expected_revision and current_revision != expected_revision:
            raise RuntimeError(
                f"Database revision mismatch: current={current_revision}, "
                f"expected={expected_revision} (ALEMBIC_EXPECTED_REVISION). "
                "Run `alembic upgrade head` or update the env var."
            )
