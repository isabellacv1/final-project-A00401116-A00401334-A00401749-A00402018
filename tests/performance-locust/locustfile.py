"""
CircleGuard load test (HU-32).

Two scenarios from the project statement:
  - Access validation: a user gets a QR token from auth and the gate validates it (gateway).
  - Health survey submission: a user submits the symptom questionnaire (form).

The services listen on different ports of the same host, so the requests use absolute URLs
built from TARGET_HOST. Run it with run-load-test.sh, which sets the users, rate and duration.

Environment variables:
  TARGET_HOST    host or IP of the environment (required), e.g. 54.83.254.142
  LOAD_USERNAME  test user (default: health_user)
  LOAD_PASSWORD  test user password (required)
  P95_TARGET_MS  p95 objective in ms for every request type (default: 500)
  MAX_ERROR_RATE maximum error rate, 0..1 (default: 0.01)
"""

import os
import time
from datetime import date

from locust import HttpUser, between, events, task

TARGET_HOST = os.environ.get("TARGET_HOST", "localhost")
AUTH_URL = os.environ.get("AUTH_URL", f"http://{TARGET_HOST}:8180")
GATEWAY_URL = os.environ.get("GATEWAY_URL", f"http://{TARGET_HOST}:8087")
FORM_URL = os.environ.get("FORM_URL", f"http://{TARGET_HOST}:8086")

USERNAME = os.environ.get("LOAD_USERNAME", "health_user")
PASSWORD = os.environ.get("LOAD_PASSWORD", "")

P95_TARGET_MS = float(os.environ.get("P95_TARGET_MS", "500"))
MAX_ERROR_RATE = float(os.environ.get("MAX_ERROR_RATE", "0.01"))

# QR tokens expire after 60 s (QR_EXPIRATION in the deploy compose); renew a bit before.
QR_RENEW_SECONDS = 45


def login(user):
    """Logs in and stores the JWT and anonymous id on the Locust user."""
    with user.client.post(
        f"{AUTH_URL}/api/v1/auth/login",
        json={"username": USERNAME, "password": PASSWORD},
        name="auth: login",
        catch_response=True,
    ) as response:
        if response.status_code != 200:
            response.failure(f"login returned {response.status_code}")
            return False
        body = response.json()
        user.jwt = body.get("token")
        user.anonymous_id = body.get("anonymousId")
        if not user.jwt or not user.anonymous_id:
            response.failure("login response without token or anonymousId")
            return False
        return True


class AccessValidationUser(HttpUser):
    """Scenario 1: QR access validation at the campus gate (the most frequent operation)."""

    weight = 3
    wait_time = between(1, 3)
    host = AUTH_URL

    def on_start(self):
        self.jwt = None
        self.anonymous_id = None
        self.qr_token = None
        self.qr_issued_at = 0.0
        login(self)

    def renew_qr(self):
        with self.client.get(
            f"{AUTH_URL}/api/v1/auth/qr/generate",
            headers={"Authorization": f"Bearer {self.jwt}"},
            name="auth: generate QR",
            catch_response=True,
        ) as response:
            if response.status_code != 200 or "qrToken" not in response.text:
                response.failure(f"QR generation returned {response.status_code}")
                return
            self.qr_token = response.json()["qrToken"]
            self.qr_issued_at = time.time()

    @task
    def validate_access(self):
        if not self.jwt and not login(self):
            return
        if not self.qr_token or time.time() - self.qr_issued_at > QR_RENEW_SECONDS:
            self.renew_qr()
            if not self.qr_token:
                return
        with self.client.post(
            f"{GATEWAY_URL}/api/v1/gate/validate",
            json={"token": self.qr_token},
            name="gateway: validate QR",
            catch_response=True,
        ) as response:
            # A valid token must be accepted; "valid": false means the gate denied a healthy user.
            if response.status_code != 200:
                response.failure(f"validate returned {response.status_code}")
            elif '"valid":true' not in response.text.replace(" ", ""):
                response.failure("valid QR was not accepted")


class SurveySubmissionUser(HttpUser):
    """Scenario 2: health survey submission."""

    weight = 1
    wait_time = between(2, 5)
    host = FORM_URL

    def on_start(self):
        self.jwt = None
        self.anonymous_id = None
        login(self)

    @task
    def submit_survey(self):
        if not self.anonymous_id and not login(self):
            return
        # No symptoms on purpose: a symptomatic report would mark the test user as SUSPECT and
        # the gate would start denying access, changing what the access scenario measures.
        payload = {
            "anonymousId": self.anonymous_id,
            "hasFever": False,
            "hasCough": False,
            "hasShortnessOfBreath": False,
            "otherSymptoms": "",
            "exposureDate": date.today().isoformat(),
        }
        with self.client.post(
            f"{FORM_URL}/api/v1/surveys",
            json=payload,
            name="form: submit survey",
            catch_response=True,
        ) as response:
            if response.status_code != 200:
                response.failure(f"survey returned {response.status_code}")


@events.quitting.add_listener
def check_objectives(environment, **_kwargs):
    """Compares the results with the declared objectives and sets the exit code."""
    stats = environment.stats
    total = stats.total
    if total.num_requests == 0:
        print("No requests were made")
        environment.process_exit_code = 1
        return

    failed = []
    print("\n==== Objectives ====")
    for entry in stats.entries.values():
        p95 = entry.get_response_time_percentile(0.95)
        ok = p95 <= P95_TARGET_MS
        print(f"{'OK  ' if ok else 'FAIL'} {entry.name:<24} p95={p95:.0f} ms (target <= {P95_TARGET_MS:.0f} ms)")
        if not ok:
            failed.append(entry.name)

    error_rate = total.num_failures / total.num_requests
    ok = error_rate <= MAX_ERROR_RATE
    print(f"{'OK  ' if ok else 'FAIL'} error rate = {error_rate:.2%} (target <= {MAX_ERROR_RATE:.2%})")
    print(f"     throughput = {total.total_rps:.1f} req/s over {total.num_requests} requests")
    if not ok:
        failed.append("error rate")

    environment.process_exit_code = 1 if failed else 0
