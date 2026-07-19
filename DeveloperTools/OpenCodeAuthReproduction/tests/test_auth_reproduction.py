import base64
import hashlib
import json
import socket
import sys
import unittest
from pathlib import Path
from unittest import mock


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))

import opencode_auth_reproduction as auth
import scan_secrets


FAKE = "FAKE_SYNTHETIC_DO_NOT_USE_"


def fixed_bytes(size):
    return bytes(range(size))


def synthetic_response(**overrides):
    response = {
        "access_token": FAKE + "ACCESS",
        "refresh_token": FAKE + "REFRESH",
        "expires_in": 120,
    }
    response.update(overrides)
    return response


def synthetic_jwt(claims):
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")
    header = encode(json.dumps({"typ": "FAKE"}).encode())
    payload = encode(json.dumps(claims).encode())
    return f"{header}.{payload}.FAKE_SIGNATURE"


class PKCEAndAttemptTests(unittest.TestCase):
    def test_pkce_and_state_match_pinned_shapes(self):
        pkce = auth.create_pkce(fixed_bytes)
        self.assertEqual(len(pkce.verifier), 43)
        expected = base64.urlsafe_b64encode(
            hashlib.sha256(pkce.verifier.encode("ascii")).digest()
        ).rstrip(b"=").decode("ascii")
        self.assertEqual(pkce.challenge, expected)
        self.assertEqual(len(auth.create_state(fixed_bytes)), 43)

    def test_secure_defaults_produce_distinct_attempt_material(self):
        first = auth.AuthAttempt.start(now=0)
        second = auth.AuthAttempt.start(now=0)
        self.assertNotEqual(first.expected_state, second.expected_state)
        self.assertNotEqual(first.pkce.verifier, second.pkce.verifier)

    def test_success_is_single_use(self):
        attempt = auth.AuthAttempt.start(now=10, random_bytes=fixed_bytes)
        transport = auth.InMemoryTokenTransport(exchange_result=synthetic_response())
        tokens = attempt.complete(
            callback_state=attempt.expected_state,
            code=FAKE + "CODE",
            transport=transport,
            now=20,
        )
        self.assertEqual(tokens.expires_at, 140)
        self.assertEqual(transport.exchange_count, 1)
        with self.assertRaises(auth.CallbackReplay):
            attempt.complete(attempt.expected_state, FAKE + "CODE", transport, now=21)
        self.assertEqual(transport.exchange_count, 1)

    def test_state_mismatch_consumes_attempt_and_never_exchanges(self):
        attempt = auth.AuthAttempt.start(now=0, random_bytes=fixed_bytes)
        transport = auth.InMemoryTokenTransport(exchange_result=synthetic_response())
        with self.assertRaises(auth.CallbackStateMismatch):
            attempt.complete(FAKE + "WRONG_STATE", FAKE + "CODE", transport, now=1)
        with self.assertRaises(auth.CallbackReplay):
            attempt.complete(attempt.expected_state, FAKE + "CODE", transport, now=2)
        self.assertEqual(transport.exchange_count, 0)

    def test_timeout_is_terminal(self):
        attempt = auth.AuthAttempt.start(now=5, timeout_seconds=10, random_bytes=fixed_bytes)
        transport = auth.InMemoryTokenTransport(exchange_result=synthetic_response())
        with self.assertRaises(auth.CallbackTimedOut) as raised:
            attempt.complete(attempt.expected_state, FAKE + "CODE", transport, now=15)
        self.assertEqual(raised.exception.failure_code, auth.FailureCode.TIMED_OUT)
        with self.assertRaises(auth.CallbackTimedOut):
            attempt.complete(attempt.expected_state, FAKE + "CODE", transport, now=16)

    def test_cancellation_is_terminal(self):
        attempt = auth.AuthAttempt.start(now=0, random_bytes=fixed_bytes)
        attempt.cancel(now=1)
        with self.assertRaises(auth.CallbackCancelled) as raised:
            attempt.complete(
                attempt.expected_state,
                FAKE + "CODE",
                auth.InMemoryTokenTransport(exchange_result=synthetic_response()),
                now=2,
            )
        self.assertEqual(raised.exception.failure_code, auth.FailureCode.CANCELLED)


class TokenAndRefreshTests(unittest.TestCase):
    def test_default_and_explicit_expiry_calculation(self):
        defaulted = synthetic_response()
        defaulted.pop("expires_in")
        self.assertEqual(auth.TokenSet.decode(defaulted, now=100).expires_at, 3700)
        self.assertEqual(auth.TokenSet.decode(synthetic_response(), now=100).expires_at, 220)

    def test_malformed_synthetic_token_data_is_rejected(self):
        malformed = [
            {},
            {"access_token": "", "refresh_token": FAKE + "REFRESH"},
            {"access_token": FAKE + "ACCESS", "refresh_token": 7},
            synthetic_response(expires_in=True),
            synthetic_response(expires_in=-1),
        ]
        for response in malformed:
            with self.subTest(response_keys=sorted(response)):
                with self.assertRaises(auth.MalformedTokenResponse):
                    auth.TokenSet.decode(response, now=0)

    def test_optional_account_id_claim_priority_and_fallback(self):
        claims = {
            "chatgpt_account_id": FAKE + "DIRECT_ACCOUNT",
            "https://api.openai.com/auth": {"chatgpt_account_id": FAKE + "NESTED_ACCOUNT"},
            "organizations": [{"id": FAKE + "ORG"}],
        }
        tokens = auth.TokenSet.decode(
            synthetic_response(id_token=synthetic_jwt(claims)), now=0
        )
        self.assertEqual(auth.extract_account_id(tokens), FAKE + "DIRECT_ACCOUNT")

        fallback = auth.TokenSet.decode(
            synthetic_response(
                id_token="not-a-jwt",
                access_token=synthetic_jwt({"organizations": [{"id": FAKE + "ORG"}]}),
            ),
            now=0,
        )
        self.assertEqual(auth.extract_account_id(fallback), FAKE + "ORG")

        malformed = auth.TokenSet.decode(
            synthetic_response(id_token="a.!.b"), now=0
        )
        self.assertIsNone(auth.extract_account_id(malformed))

    def test_refresh_needed_transition_and_account_retention(self):
        session = auth.AuthSession(
            tokens=auth.TokenSet.decode(synthetic_response(expires_in=10), now=100),
            account_id=FAKE + "ORIGINAL_ACCOUNT",
        )
        transport = auth.InMemoryTokenTransport(refresh_result=synthetic_response(expires_in=30))
        self.assertEqual(session.state_at(110), auth.SessionState.READY)
        self.assertEqual(session.state_at(111), auth.SessionState.REFRESH_NEEDED)
        self.assertEqual(session.refresh_if_needed(transport, 111), auth.SessionState.READY)
        self.assertEqual(session.tokens.expires_at, 141)
        self.assertEqual(session.account_id, FAKE + "ORIGINAL_ACCOUNT")
        self.assertEqual(transport.refresh_count, 1)

    def test_auth_needed_and_unavailable_mapping(self):
        self.assertEqual(auth.AuthSession().state_at(0), auth.SessionState.AUTH_NEEDED)
        unavailable = auth.ServiceUnavailable("synthetic outage")
        required = auth.AuthRequired("synthetic reauth")
        self.assertEqual(unavailable.failure_code, auth.FailureCode.UNAVAILABLE)
        self.assertEqual(required.failure_code, auth.FailureCode.UNAUTHORIZED)


class HeaderRedactionAndHermeticityTests(unittest.TestCase):
    def test_authenticated_headers_replace_caller_auth_and_redact_all_diagnostics(self):
        canary = FAKE + "ACCESS_CANARY"
        headers = auth.build_authenticated_headers(
            {
                "authorization": "Bearer " + FAKE + "CALLER_VALUE",
                "X-Selection-Excerpt": FAKE + "USER_CONTENT",
            },
            access_token=canary,
            account_id=FAKE + "ACCOUNT",
        )
        transport_headers = headers.for_in_memory_transport()
        self.assertEqual(transport_headers["Authorization"], "Bearer " + canary)
        self.assertNotIn("authorization", transport_headers)
        diagnostic = json.dumps(headers.diagnostic_headers())
        representation = repr(headers)
        self.assertNotIn(canary, diagnostic + representation)
        self.assertNotIn(FAKE + "USER_CONTENT", diagnostic + representation)
        self.assertTrue(all(value == "[REDACTED]" for value in headers.diagnostic_headers().values()))

    def test_full_success_and_refresh_flow_survives_network_denial(self):
        with mock.patch.object(socket.socket, "connect", side_effect=AssertionError("network denied")), mock.patch(
            "socket.create_connection", side_effect=AssertionError("network denied")
        ):
            attempt = auth.AuthAttempt.start(now=0, random_bytes=fixed_bytes)
            transport = auth.InMemoryTokenTransport(
                exchange_result=synthetic_response(expires_in=1),
                refresh_result=synthetic_response(expires_in=30),
            )
            tokens = attempt.complete(
                attempt.expected_state, FAKE + "CODE", transport, now=1
            )
            session = auth.AuthSession(tokens=tokens)
            self.assertEqual(session.refresh_if_needed(transport, now=3), auth.SessionState.READY)

    def test_implementation_has_no_network_client_imports(self):
        source = (HARNESS_DIR / "opencode_auth_reproduction.py").read_text()
        for forbidden in ("import socket", "import urllib", "import http", "import requests"):
            self.assertNotIn(forbidden, source)

    def test_secret_scanner_rejects_credential_shapes_without_echoing_values(self):
        provider_key = "sk" + "-" + "A" * 24
        bearer = "Bearer " + "B" * 24
        findings = scan_secrets.findings_for_text(
            provider_key + "\n" + bearer, scan_secrets.SOURCE_RULES
        )
        self.assertIn("provider-key", findings)
        self.assertIn("bearer-literal", findings)
        self.assertNotIn(provider_key, findings)

    def test_secret_scanner_allows_unmistakably_fake_source_fixture(self):
        text = "Bearer " + FAKE + "ACCESS"
        self.assertEqual(
            scan_secrets.findings_for_text(text, scan_secrets.SOURCE_RULES), []
        )


if __name__ == "__main__":
    unittest.main()
