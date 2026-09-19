#!/usr/bin/env python3
"""
common.py — Unified Interfaces, Typed Dataclasses, and Common Utilities for Social Poster.
"""

from abc import ABC, abstractmethod
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from typing import Any


@dataclass
class PostResult:
    platform: str
    status: str  # "LIVE", "DRY_RUN", "ERROR", "SKIPPED"
    url: str | None = None
    post_id: str | None = None
    title: str | None = None
    error: str | None = None
    timestamp: str = field(
        default_factory=lambda: datetime.now(UTC).isoformat()
    )
    metadata: dict[str, Any] = field(default_factory=dict)
    raw_response: Any | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class SocialPlatformAdapter(ABC):
    """Abstract base class for all deterministic platform adapters."""

    def __init__(self, name: str, timeout: int = 600):
        self.name = name
        self.timeout = timeout

    @abstractmethod
    def authenticate(self) -> bool:
        """Authenticate or verify session credentials. Returns True if valid."""

    @abstractmethod
    def validate_draft(self, draft_payload: dict[str, Any]) -> list[str]:
        """Pre-flight validation of constraints. Returns list of error messages (empty if valid)."""

    @abstractmethod
    def publish(
        self, draft_payload: dict[str, Any], dry_run: bool = False
    ) -> PostResult:
        """Execute post publication or return dry-run validation result."""
