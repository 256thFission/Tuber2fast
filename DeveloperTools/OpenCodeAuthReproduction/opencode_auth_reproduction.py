"""Hermetic behavior-level reproduction of selected OpenCode Codex auth behavior.

This module is development tooling. It performs no network or credential storage.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import math
import secrets
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Dict, Mapping, Optional, Protocol


_PKCE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
_REDACTED = "[REDACTED]"


class FailureCode(str, Enum):
    """Local comparison vocabulary; this does not import or change product contracts."""

    UNAVAILABLE = "unavailable"
    UNAUTHORIZED = "unauthorized"
    TIMED_OUT = "timedOut"
    INVALID_RESPONSE = "invalidResponse"
    CANCELLED = "cancelled"


class ReproductionError(Exception):
    failure_code = FailureCode.INVALID_RESPONSE


class AuthRequired(ReproductionError):
    failure_code = FailureCode.UNAUTHORIZED


class CallbackTimedOut(ReproductionError):
    failure_code = FailureCode.TIMED_OUT


class CallbackCancelled(ReproductionError):
    failure_code = FailureCode.CANCELLED


class ServiceUnavailable(ReproductionError):
    failure_code = FailureCode.UNAVAILABLE


class CallbackStateMismatch(ReproductionError):
    pass


class CallbackReplay(ReproductionError):
    pass


class MalformedTokenResponse(ReproductionError):
    pass


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


@dataclass(frozen=True)
class PKCECodes:
    verifier: str
    challenge: str


def create_pkce(random_bytes: Optional[Callable[[int], bytes]] = None) -> PKCECodes:
    """Create the pinned adapter's 43-character verifier and S256 challenge."""

    source = random_bytes or secrets.token_bytes
    entropy = source(43)
    if len(entropy) != 43:
        raise ValueError("random source must return exactly 43 bytes")
    verifier = "".join(_PKCE_ALPHABET[value % len(_PKCE_ALPHABET)] for value in entropy)
    challenge = _base64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return PKCECodes(verifier=verifier, challenge=challenge)


def create_state(random_bytes: Optional[Callable[[int], bytes]] = None) -> str:
    source = random_bytes or secrets.token_bytes
    entropy = source(32)
    if len(entropy) != 32:
        raise ValueError("random source must return exactly 32 bytes")
    return _base64url(entropy)


def _required_nonempty_string(response: Mapping[str, Any], key: str) -> str:
    value = response.get(key)
    if not isinstance(value, str) or not value:
        raise MalformedTokenResponse("synthetic token response has an invalid field")
    return value


@dataclass(frozen=True)
class TokenSet:
    access_token: str
    refresh_token: str
    expires_at: float
    id_token: Optional[str] = None

    @classmethod
    def decode(cls, response: Mapping[str, Any], now: float) -> "TokenSet":
        if not isinstance(response, Mapping):
            raise MalformedTokenResponse("synthetic token response is not an object")

        access_token = _required_nonempty_string(response, "access_token")
        refresh_token = _required_nonempty_string(response, "refresh_token")
        id_token = response.get("id_token")
        if id_token is not None and (not isinstance(id_token, str) or not id_token):
            raise MalformedTokenResponse("synthetic token response has an invalid field")

        expires_in = response.get("expires_in", 3600)
        if (
            isinstance(expires_in, bool)
            or not isinstance(expires_in, (int, float))
            or not math.isfinite(float(expires_in))
            or expires_in <= 0
        ):
            raise MalformedTokenResponse("synthetic token response has an invalid expiry")

        return cls(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_at=now + float(expires_in),
            id_token=id_token,
        )


def _decode_jwt_claims(token: str) -> Optional[Mapping[str, Any]]:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (binascii.Error, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return claims if isinstance(claims, Mapping) else None


def _account_id_from_claims(claims: Mapping[str, Any]) -> Optional[str]:
    direct = claims.get("chatgpt_account_id")
    if isinstance(direct, str) and direct:
        return direct

    namespaced = claims.get("https://api.openai.com/auth")
    if isinstance(namespaced, Mapping):
        value = namespaced.get("chatgpt_account_id")
        if isinstance(value, str) and value:
            return value

    organizations = claims.get("organizations")
    if isinstance(organizations, list) and organizations:
        first = organizations[0]
        if isinstance(first, Mapping):
            value = first.get("id")
            if isinstance(value, str) and value:
                return value
    return None


def extract_account_id(tokens: TokenSet) -> Optional[str]:
    for token in (tokens.id_token, tokens.access_token):
        if not token:
            continue
        claims = _decode_jwt_claims(token)
        if claims:
            account_id = _account_id_from_claims(claims)
            if account_id:
                return account_id
    return None


class TokenTransport(Protocol):
    def exchange_code(self, code: str, verifier: str) -> Mapping[str, Any]:
        ...

    def refresh(self, refresh_token: str) -> Mapping[str, Any]:
        ...


class InMemoryTokenTransport:
    """Scripted transport that deliberately records counts, never auth inputs."""

    def __init__(
        self,
        exchange_result: Any = None,
        refresh_result: Any = None,
    ) -> None:
        self._exchange_result = exchange_result
        self._refresh_result = refresh_result
        self.exchange_count = 0
        self.refresh_count = 0

    @staticmethod
    def _resolve(result: Any) -> Mapping[str, Any]:
        if isinstance(result, Exception):
            raise result
        if not isinstance(result, Mapping):
            raise ServiceUnavailable("scripted transport has no synthetic response")
        return dict(result)

    def exchange_code(self, code: str, verifier: str) -> Mapping[str, Any]:
        del code, verifier
        self.exchange_count += 1
        return self._resolve(self._exchange_result)

    def refresh(self, refresh_token: str) -> Mapping[str, Any]:
        del refresh_token
        self.refresh_count += 1
        return self._resolve(self._refresh_result)


class AttemptStatus(str, Enum):
    PENDING = "pending"
    COMPLETED = "completed"
    REJECTED = "rejected"
    TIMED_OUT = "timedOut"
    CANCELLED = "cancelled"


@dataclass
class AuthAttempt:
    pkce: PKCECodes
    expected_state: str
    deadline: float
    status: AttemptStatus = AttemptStatus.PENDING

    @classmethod
    def start(
        cls,
        now: float,
        timeout_seconds: float = 300,
        random_bytes: Optional[Callable[[int], bytes]] = None,
    ) -> "AuthAttempt":
        if timeout_seconds <= 0:
            raise ValueError("timeout must be positive")
        return cls(
            pkce=create_pkce(random_bytes),
            expected_state=create_state(random_bytes),
            deadline=now + timeout_seconds,
        )

    def _require_pending(self, now: float) -> None:
        if self.status == AttemptStatus.CANCELLED:
            raise CallbackCancelled("authorization was cancelled")
        if self.status == AttemptStatus.TIMED_OUT:
            raise CallbackTimedOut("authorization timed out")
        if self.status != AttemptStatus.PENDING:
            raise CallbackReplay("authorization callback was already consumed")
        if now >= self.deadline:
            self.status = AttemptStatus.TIMED_OUT
            raise CallbackTimedOut("authorization timed out")

    def cancel(self, now: float) -> None:
        self._require_pending(now)
        self.status = AttemptStatus.CANCELLED

    def complete(
        self,
        callback_state: str,
        code: str,
        transport: TokenTransport,
        now: float,
    ) -> TokenSet:
        self._require_pending(now)
        if callback_state != self.expected_state:
            self.status = AttemptStatus.REJECTED
            raise CallbackStateMismatch("callback state did not exactly match")
        if not code:
            self.status = AttemptStatus.REJECTED
            raise MalformedTokenResponse("authorization callback omitted its code")

        # The callback becomes single-use before exchange, matching the pinned behavior.
        self.status = AttemptStatus.COMPLETED
        response = transport.exchange_code(code=code, verifier=self.pkce.verifier)
        return TokenSet.decode(response, now=now)


class SessionState(str, Enum):
    AUTH_NEEDED = "authNeeded"
    READY = "ready"
    REFRESH_NEEDED = "refreshNeeded"


@dataclass
class AuthSession:
    tokens: Optional[TokenSet] = None
    account_id: Optional[str] = None

    def state_at(self, now: float) -> SessionState:
        if self.tokens is None:
            return SessionState.AUTH_NEEDED
        # The pinned adapter refreshes only after expiry, not at the exact boundary.
        if self.tokens.expires_at < now:
            return SessionState.REFRESH_NEEDED
        return SessionState.READY

    def refresh_if_needed(self, transport: TokenTransport, now: float) -> SessionState:
        state = self.state_at(now)
        if state != SessionState.REFRESH_NEEDED:
            return state
        assert self.tokens is not None
        response = transport.refresh(self.tokens.refresh_token)
        refreshed = TokenSet.decode(response, now=now)
        self.tokens = refreshed
        self.account_id = extract_account_id(refreshed) or self.account_id
        return SessionState.READY


class AuthenticatedHeaders:
    """Holds transport headers while exposing only redacted diagnostics and repr."""

    def __init__(self, headers: Mapping[str, str]) -> None:
        self._headers = dict(headers)

    def for_in_memory_transport(self) -> Dict[str, str]:
        return dict(self._headers)

    def diagnostic_headers(self) -> Dict[str, str]:
        return {name: _REDACTED for name in self._headers}

    def __repr__(self) -> str:
        names = sorted(self._headers, key=str.lower)
        return f"AuthenticatedHeaders(names={names!r}, values={_REDACTED!r})"


def build_authenticated_headers(
    existing: Mapping[str, str],
    access_token: str,
    account_id: Optional[str] = None,
) -> AuthenticatedHeaders:
    if not access_token:
        raise AuthRequired("an access credential is required")
    headers = {
        name: value
        for name, value in existing.items()
        if name.lower() != "authorization"
    }
    headers["Authorization"] = f"Bearer {access_token}"
    if account_id:
        headers["ChatGPT-Account-Id"] = account_id
    return AuthenticatedHeaders(headers)
