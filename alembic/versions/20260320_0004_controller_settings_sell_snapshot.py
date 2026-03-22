"""controller_settings sell price snapshot

Revision ID: 20260320_0004
Revises: 20260320_0003
Create Date: 2026-03-20 12:00:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260320_0004"
down_revision: Union[str, None] = "20260320_0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "controller_settings",
        sa.Column("sell_ranges_json", sa.Text(), nullable=True),
    )
    op.add_column(
        "controller_settings",
        sa.Column("sell_priority_tokens_json", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("controller_settings", "sell_priority_tokens_json")
    op.drop_column("controller_settings", "sell_ranges_json")
