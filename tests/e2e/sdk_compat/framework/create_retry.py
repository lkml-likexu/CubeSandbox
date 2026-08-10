# Copyright (c) 2026 Tencent Inc.
# SPDX-License-Identifier: Apache-2.0

"""Retry sandbox creation when the scheduler is temporarily out of capacity.

A shared CI environment can transiently reject ``create`` calls when every node
is saturated. The scheduler reports this as ``no more resource`` (see
``CubeMaster/pkg/scheduler`` ``ErrNoRes`` / ``ErrorCode_SelectNodesNoRes``),
which the SDK surfaces as an ``ApiError``. That condition clears on its own once
another sandbox is torn down, so the E2E harness retries with exponential
backoff instead of failing the whole run.

Only capacity errors are retried; every other failure (bad template, auth,
``ImportError`` for a missing SDK, …) propagates immediately.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import TypeVar

T = TypeVar("T")

# Substrings that identify a transient "scheduler is out of capacity" failure.
# Matched case-insensitively against the exception message.
_CAPACITY_MARKERS = (
    "no more resource",
    "resource exhausted",
    "select nodes",
    "selectnodesnores",
    "out of capacity",
    "insufficient capacity",
)


def is_capacity_error(exc: BaseException) -> bool:
    """Return ``True`` when ``exc`` looks like a transient out-of-capacity error."""
    message = str(exc).lower()
    return any(marker in message for marker in _CAPACITY_MARKERS)


def create_with_capacity_retry(
    create: Callable[[], T],
    *,
    retries: int,
    backoff: float,
    backoff_max: float,
    on_retry: Callable[[int, float, BaseException], None] | None = None,
) -> T:
    """Call ``create`` and retry it while the scheduler is out of capacity.

    Args:
        create: Zero-argument callable that creates and returns the sandbox
            adapter. Invoked once per attempt.
        retries: Maximum number of *additional* attempts after the first one.
            ``0`` disables retrying (a single attempt). Negative values are
            treated as ``0``.
        backoff: Base delay, in seconds, before the first retry. Each subsequent
            retry doubles the delay (exponential backoff).
        backoff_max: Upper bound, in seconds, for any single backoff delay.
        on_retry: Optional callback invoked before each sleep with
            ``(attempt, delay, exc)`` where ``attempt`` is 1-based.

    Returns:
        Whatever ``create`` returns on the first successful attempt.

    Raises:
        The last capacity error once ``retries`` is exhausted, or immediately
        re-raises any non-capacity error.
    """
    max_retries = max(0, retries)
    attempt = 0
    while True:
        try:
            return create()
        except Exception as exc:  # noqa: BLE001 - decide per-exception whether to retry
            if attempt >= max_retries or not is_capacity_error(exc):
                raise
            attempt += 1
            delay = _backoff_delay(attempt, backoff, backoff_max)
            if on_retry is not None:
                on_retry(attempt, delay, exc)
            time.sleep(delay)


def _backoff_delay(attempt: int, backoff: float, backoff_max: float) -> float:
    """Exponential backoff for a 1-based ``attempt``, capped at ``backoff_max``."""
    delay = backoff * (2 ** (attempt - 1))
    if backoff_max > 0:
        delay = min(delay, backoff_max)
    return max(0.0, delay)

