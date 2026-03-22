"""accounts inventory snapshot from worker bridge

Revision ID: 20260320_0005
Revises: 20260320_0004
Create Date: 2026-03-20 14:00:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260320_0005"
down_revision: Union[str, None] = "20260320_0004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "accounts",
        sa.Column("inventory_json", sa.Text(), nullable=True),
    )
    op.add_column(
        "accounts",
        sa.Column("inventory_updated_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("accounts", "inventory_updated_at")
    op.drop_column("accounts", "inventory_json")
