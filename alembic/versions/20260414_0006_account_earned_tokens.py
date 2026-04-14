"""accounts earned_tokens from death reward cycles

Revision ID: 20260414_0006
Revises: 20260320_0005
Create Date: 2026-04-14 22:30:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260414_0006"
down_revision: Union[str, None] = "20260320_0005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "accounts",
        sa.Column("earned_tokens_json", sa.Text(), nullable=True),
    )
    op.add_column(
        "accounts",
        sa.Column("earned_tokens_updated_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("accounts", "earned_tokens_updated_at")
    op.drop_column("accounts", "earned_tokens_json")
