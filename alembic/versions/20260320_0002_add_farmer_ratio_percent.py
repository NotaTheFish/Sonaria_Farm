"""add farmer_ratio_percent to controller_settings

Revision ID: 20260320_0002
Revises: 20260319_0001
Create Date: 2026-03-20 00:00:00.000000
"""

from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = "20260320_0002"
down_revision: Union[str, None] = "20260319_0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Если колонка уже есть (например при повторном запуске), не падаем.
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'controller_settings'
                  AND column_name = 'farmer_ratio_percent'
            ) THEN
                ALTER TABLE controller_settings
                ADD COLUMN farmer_ratio_percent integer NOT NULL DEFAULT 70;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'controller_settings'
                  AND column_name = 'farmer_ratio_percent'
            ) THEN
                ALTER TABLE controller_settings
                DROP COLUMN farmer_ratio_percent;
            END IF;
        END $$;
        """
    )

