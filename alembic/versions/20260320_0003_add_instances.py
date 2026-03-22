"""add instances table

Revision ID: 20260320_0003
Revises: 20260320_0002
Create Date: 2026-03-20 00:30:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "20260320_0003"
down_revision: Union[str, None] = "20260320_0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "instances",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("host", sa.String(length=255), nullable=True),
        sa.Column("name", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("worker_id", sa.String(length=36), nullable=True),
        sa.Column("account_id", sa.String(length=36), nullable=True),
        sa.Column("last_heartbeat_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("meta_json", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"]),
        sa.ForeignKeyConstraint(["worker_id"], ["workers.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name"),
    )
    op.create_index("ix_instances_host", "instances", ["host"], unique=False)
    op.create_index("ix_instances_name", "instances", ["name"], unique=False)
    op.create_index("ix_instances_status", "instances", ["status"], unique=False)
    op.create_index("ix_instances_worker_id", "instances", ["worker_id"], unique=False)
    op.create_index("ix_instances_account_id", "instances", ["account_id"], unique=False)
    op.create_index("ix_instances_last_heartbeat_at", "instances", ["last_heartbeat_at"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_instances_last_heartbeat_at", table_name="instances")
    op.drop_index("ix_instances_account_id", table_name="instances")
    op.drop_index("ix_instances_worker_id", table_name="instances")
    op.drop_index("ix_instances_status", table_name="instances")
    op.drop_index("ix_instances_name", table_name="instances")
    op.drop_index("ix_instances_host", table_name="instances")
    op.drop_table("instances")

