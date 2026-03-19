import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from db import Base


class AccountRole(str, enum.Enum):
    FARMER = "FARMER"
    STORAGE = "STORAGE"


class AccountStatus(str, enum.Enum):
    ACTIVE = "ACTIVE"
    BANNED = "BANNED"
    SLEEP = "SLEEP"


class Account(Base):
    __tablename__ = "accounts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    login: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    password: Mapped[str] = mapped_column(Text, nullable=False)

    role: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    status: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    banned_reason: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )


class ControllerSettings(Base):
    """
    Глобальные настройки контроллера.
    """

    __tablename__ = "controller_settings"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    death_points_target: Mapped[int] = mapped_column(Integer, nullable=False, default=600)
    farming_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    sales_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )


__all__ = [
    "Account",
    "AccountRole",
    "AccountStatus",
    "ControllerSettings",
]

