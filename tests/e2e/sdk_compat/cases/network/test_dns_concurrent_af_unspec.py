# Copyright (c) 2026 Tencent Inc.
# SPDX-License-Identifier: Apache-2.0

"""Minimal reproduction for issue #1406.

Concurrent A/AAAA (``AF_UNSPEC``) resolution inside a sandbox intermittently
fails with ``EAI_AGAIN`` ("Temporary failure in name resolution"), while
A-only and AAAA-only lookups are reliable and glibc ``RES_OPTIONS=single-request``
(which serializes the paired queries) makes ``AF_UNSPEC`` reliable again.

This embeds the issue's original ``getaddrinfo`` loop verbatim (only its output
is made machine-parseable) and turns it into a regression gate:

* ``AF_INET`` establishes that DNS + IPv4 egress work at all (environment sanity).
* ``AF_UNSPEC`` + ``single-request`` is the control: the paired queries are
  serialized, so this is expected to be fully reliable.
* ``AF_UNSPEC`` (default) is the subject: glibc sends the A and AAAA queries
  concurrently on the same UDP source port. On an affected build this is where
  the sandbox UDP/TAP data path drops one of the pair.

If the subject is materially less reliable than the (serialized) control while
both baselines are healthy, #1406 is reproduced and the test FAILS. On a fixed
build all three are reliable and the test passes.
"""

from __future__ import annotations

import json
import math
import os
import shlex

import pytest

from framework.assertions import assert_command_ok

pytestmark = [
    pytest.mark.e2e,
    pytest.mark.sdk_compat,
    pytest.mark.network,
    pytest.mark.p2,
    pytest.mark.slow,
    pytest.mark.requires_internet,
]

# A public hostname with both A and AAAA records, matching the issue report.
REPRO_HOST = os.environ.get("SDK_E2E_DNS_REPRO_HOST", "www.example.com")
REPRO_PORT = int(os.environ.get("SDK_E2E_DNS_REPRO_PORT", "443"))
# 30 concurrent-pair attempts per family, as in the issue's AF_UNSPEC cases.
REPRO_ATTEMPTS = int(os.environ.get("SDK_E2E_DNS_REPRO_ATTEMPTS", "30"))
# Amplify the failure: 1s timeout and no glibc-level retry, so a single dropped
# query surfaces as one lost attempt instead of being masked by a resolver retry.
BASE_RES_OPTIONS = os.environ.get("SDK_E2E_DNS_REPRO_RES_OPTIONS", "timeout:1 attempts:1")

# The issue's original script, with its ``print(...)`` replaced by a stable
# ``RESULT:<json>`` line so the harness can parse it deterministically.
_REPRO_SCRIPT = (
    "import json, os, socket\n"
    "family = getattr(socket, os.environ['FAMILY'])\n"
    "attempts = int(os.environ.get('ATTEMPTS', '30'))\n"
    "host = os.environ.get('HOST', 'www.example.com')\n"
    "port = int(os.environ.get('PORT', '443'))\n"
    "success = 0\n"
    "errors = {}\n"
    "for _ in range(attempts):\n"
    "    try:\n"
    "        socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)\n"
    "        success += 1\n"
    "    except OSError as exc:\n"
    "        errors[str(exc)] = errors.get(str(exc), 0) + 1\n"
    "print('RESULT:' + json.dumps({\n"
    "    'family': os.environ['FAMILY'],\n"
    "    'attempts': attempts,\n"
    "    'success': success,\n"
    "    'errors': errors,\n"
    "}))\n"
)


def _repro_command(family: str, res_options: str) -> str:
    """Build the in-sandbox command running the repro script for one family."""
    env_prefix = (
        f"FAMILY={family} "
        f"ATTEMPTS={REPRO_ATTEMPTS} "
        f"HOST={shlex.quote(REPRO_HOST)} "
        f"PORT={REPRO_PORT} "
        f"RES_OPTIONS={shlex.quote(res_options)}"
    )
    return f"{env_prefix} python3 - <<'PY'\n{_REPRO_SCRIPT}PY"


def _run_repro(sdk_sandbox, sdk_e2e_config, family: str, res_options: str) -> dict:
    """Run one family/RES_OPTIONS combination and return the parsed RESULT dict."""
    # Each failing attempt can wait up to ~1s (timeout:1 attempts:1); size the
    # command timeout to comfortably cover an all-failing run plus startup.
    command_timeout = max(sdk_e2e_config.command_timeout, REPRO_ATTEMPTS * 3 + 30)
    result = sdk_sandbox.run_command(
        _repro_command(family, res_options),
        timeout=command_timeout,
    )
    assert_command_ok(result)
    line = next(
        (
            ln.strip()[len("RESULT:") :]
            for ln in result.stdout.splitlines()
            if ln.strip().startswith("RESULT:")
        ),
        None,
    )
    assert line is not None, (
        f"repro script produced no RESULT line for FAMILY={family}; "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )
    return json.loads(line)


@pytest.mark.sandbox_create_options(allow_internet_access=True)
def test_concurrent_af_unspec_resolution_matches_single_request(
    sdk_sandbox,
    sdk_e2e_config,
):
    """AF_UNSPEC must be as reliable as single-stack / serialized resolution."""
    # A dropped attempt on the buggy path costs ~10% of the runs in the issue's
    # report (9/30). Tolerate only genuine sporadic upstream loss, well below the
    # ~70% failure the bug produces.
    tolerance = max(2, math.ceil(REPRO_ATTEMPTS * 0.1))

    v4 = _run_repro(sdk_sandbox, sdk_e2e_config, "AF_INET", BASE_RES_OPTIONS)
    control = _run_repro(
        sdk_sandbox,
        sdk_e2e_config,
        "AF_UNSPEC",
        f"single-request {BASE_RES_OPTIONS}",
    )
    subject = _run_repro(sdk_sandbox, sdk_e2e_config, "AF_UNSPEC", BASE_RES_OPTIONS)

    context = f"v4={v4!r} control(single-request)={control!r} subject={subject!r}"

    # Environment sanity: if plain IPv4 resolution or the serialized dual-stack
    # control is already unreliable, DNS/egress is broken in this lab and the
    # concurrency-specific bug cannot be isolated. Skip rather than mislabel it.
    if v4["success"] < REPRO_ATTEMPTS - tolerance:
        pytest.skip(f"IPv4 DNS/egress unreliable in this environment; {context}")
    if control["success"] < REPRO_ATTEMPTS - tolerance:
        pytest.skip(
            "serialized (single-request) AF_UNSPEC resolution is unreliable; "
            f"DNS/egress environment issue, not the concurrency bug; {context}"
        )

    # The regression gate: concurrent AF_UNSPEC must not be materially worse than
    # the serialized control. A large drop reproduces issue #1406 (one of the
    # concurrent A/AAAA queries is lost in the sandbox UDP/TAP path).
    assert subject["success"] >= control["success"] - tolerance, (
        "concurrent AF_UNSPEC resolution is significantly less reliable than "
        "serialized (single-request) resolution: this reproduces issue #1406 "
        "(concurrent A/AAAA queries share one UDP source port and one is dropped "
        "in the sandbox UDP/TAP data path). Workaround: RES_OPTIONS=single-request. "
        f"tolerance={tolerance} {context}"
    )
