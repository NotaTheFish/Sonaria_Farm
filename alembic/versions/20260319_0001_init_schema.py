"""init schema

Revision ID: 20260319_0001
Revises:
Create Date: 2026-03-19 00:00:00.000000
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "20260319_0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "accounts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("login", sa.String(length=255), nullable=False),
        sa.Column("password", sa.Text(), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=True),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("banned_reason", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("login"),
    )
    op.create_index("ix_accounts_role", "accounts", ["role"], unique=False)
    op.create_index("ix_accounts_status", "accounts", ["status"], unique=False)

    op.create_table(
        "controller_settings",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("death_points_target", sa.Integer(), nullable=False),
        sa.Column("farmer_ratio_percent", sa.Integer(), nullable=False),
        sa.Column("farming_enabled", sa.Boolean(), nullable=False),
        sa.Column("sales_enabled", sa.Boolean(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "workers",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("account_id", sa.String(length=36), nullable=True),
        sa.Column("hostname", sa.String(length=255), nullable=True),
        sa.Column("heartbeat_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_workers_account_id", "workers", ["account_id"], unique=False)
    op.create_index("ix_workers_heartbeat_at", "workers", ["heartbeat_at"], unique=False)
    op.create_index("ix_workers_last_seen_at", "workers", ["last_seen_at"], unique=False)
    op.create_index("ix_workers_role", "workers", ["role"], unique=False)

    op.create_table(
        "tasks",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("task_type", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("priority", sa.Integer(), nullable=False),
        sa.Column("account_id", sa.String(length=36), nullable=True),
        sa.Column("worker_id", sa.String(length=36), nullable=True),
        sa.Column("cancel_requested", sa.Boolean(), nullable=False),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("payload", sa.Text(), nullable=True),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("cancelled_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["account_id"], ["accounts.id"]),
        sa.ForeignKeyConstraint(["worker_id"], ["workers.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_tasks_account_id", "tasks", ["account_id"], unique=False)
    op.create_index("ix_tasks_cancel_requested", "tasks", ["cancel_requested"], unique=False)
    op.create_index("ix_tasks_created_at", "tasks", ["created_at"], unique=False)
    op.create_index("ix_tasks_lease_expires_at", "tasks", ["lease_expires_at"], unique=False)
    op.create_index("ix_tasks_priority", "tasks", ["priority"], unique=False)
    op.create_index("ix_tasks_status", "tasks", ["status"], unique=False)
    op.create_index("ix_tasks_task_type", "tasks", ["task_type"], unique=False)
    op.create_index("ix_tasks_worker_id", "tasks", ["worker_id"], unique=False)

    op.create_table(
        "task_logs",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("task_id", sa.String(length=36), nullable=False),
        sa.Column("worker_id", sa.String(length=36), nullable=True),
        sa.Column("level", sa.String(length=16), nullable=False),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["task_id"], ["tasks.id"]),
        sa.ForeignKeyConstraint(["worker_id"], ["workers.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_task_logs_created_at", "task_logs", ["created_at"], unique=False)
    op.create_index("ix_task_logs_task_id", "task_logs", ["task_id"], unique=False)
    op.create_index("ix_task_logs_worker_id", "task_logs", ["worker_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_task_logs_worker_id", table_name="task_logs")
    op.drop_index("ix_task_logs_task_id", table_name="task_logs")
    op.drop_index("ix_task_logs_created_at", table_name="task_logs")
    op.drop_table("task_logs")

    op.drop_index("ix_tasks_worker_id", table_name="tasks")
    op.drop_index("ix_tasks_task_type", table_name="tasks")
    op.drop_index("ix_tasks_status", table_name="tasks")
    op.drop_index("ix_tasks_priority", table_name="tasks")
    op.drop_index("ix_tasks_lease_expires_at", table_name="tasks")
    op.drop_index("ix_tasks_created_at", table_name="tasks")
    op.drop_index("ix_tasks_cancel_requested", table_name="tasks")
    op.drop_index("ix_tasks_account_id", table_name="tasks")
    op.drop_table("tasks")

    op.drop_index("ix_workers_role", table_name="workers")
    op.drop_index("ix_workers_last_seen_at", table_name="workers")
    op.drop_index("ix_workers_heartbeat_at", table_name="workers")
    op.drop_index("ix_workers_account_id", table_name="workers")
    op.drop_table("workers")

    op.drop_table("controller_settings")

    op.drop_index("ix_accounts_status", table_name="accounts")
    op.drop_index("ix_accounts_role", table_name="accounts")
    op.drop_table("accounts")
