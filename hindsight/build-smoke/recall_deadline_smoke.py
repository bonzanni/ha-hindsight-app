"""Build-time regression check for recall-deadline-worker-drain.patch.

Runs during `docker build` against the patched hindsight_api. It builds the
app with the PRODUCTION factory, hindsight_api.api.http.create_app, backed by a
stub engine, so the request crosses the real middleware stack, the real route
class (bank-alias resolution), the real dependencies (precheck, admission) and
the real recall endpoint.

The recall deadline is a whole-request, pure-ASGI middleware. Review rounds
found work escaping narrower deadlines three times, in three different places:
post-recall attachment enrichment, the admission queue, and bank-alias
resolution in the route class. So each slow step below has to produce a fast
504:

  alias      stub resolve_bank_alias blocks (route class, before dependencies)
             -> 504, and the engine is never called
  engine     stub recall_async blocks
             -> 504, and the operation metric records a FAILURE (the
                cancellation reaches the metrics context as CancelledError,
                which upstream's `except Exception` never saw)
  enrich     stub attachments_for_memories blocks (after the engine returned)
             -> 504, and the slow step is cancelled

In every case the HTTP request metric records the 504. With the deadline off,
the same slow request completes with 200, exactly as upstream does.

Cancellation safety of upstream's admission queue (found in review): the
deadline can now cancel a request while it waits in admission, and upstream's
_acquire_unless_abandoned leaked its orphaned acquire task, which later took a
permit and never returned it. That drains the recall lane until restart. This
file checks the helper directly (cancelled while queued; cancelled in the same
tick a permit is granted) and end to end through create_app with a one-permit
lane: a request that times out while queued must leave the lane with full
capacity for the next one.
"""

import asyncio
import contextlib
import os
import time

from fastapi.testclient import TestClient

import hindsight_api.api.http as h
from hindsight_api.engine.response_models import MemoryFact, RecallResult
from hindsight_api.metrics import MetricsCollector, NoOpMetricsCollector, reset_metrics_collector
from hindsight_api.api.admission import _acquire_unless_abandoned
from hindsight_api.cancellation import CancellationToken
from hindsight_api.config import clear_config_cache

SLOW_S = 2.0
DEADLINE = "1"
PATH = "/v1/default/banks/b1/memories/recall"
BODY = {"query": "what is the thermostat set to?"}


class _Recorder(NoOpMetricsCollector):
    """No-op collector plus the PATCHED record_operation and an HTTP status tap."""

    record_operation = MetricsCollector.record_operation  # the real (patched) context manager

    def __init__(self):
        self.operations: list[bool] = []
        self.http_status: list[int] = []

    def record_operation_result(self, operation, bank_id, success, duration, **kwargs):
        self.operations.append(success)

    @contextlib.contextmanager
    def record_http_request(self, method, endpoint, status_code_getter):
        try:
            yield
        finally:
            self.http_status.append(status_code_getter())


class _StubEngine:
    """Just enough of MemoryEngine for create_app and the recall route."""

    audit_logger = None
    _operation_validator = None

    def __init__(self):
        self.slow: str | None = None
        self.engine_called = False
        self.enrich_done = False

    async def _authenticate_tenant(self, request_context):
        return None

    async def resolve_bank_alias(self, bank_id, *, request_context):
        if self.slow == "alias":
            await asyncio.sleep(SLOW_S)  # alias lookup stuck on the DB pool
        return bank_id

    async def recall_async(self, **kwargs):
        self.engine_called = True
        if self.slow == "engine":
            await asyncio.sleep(SLOW_S)
        # One result, so the handler's unconditional attachment lookup runs.
        return RecallResult(results=[MemoryFact(id="f1", text="the thermostat is set to 21C", fact_type="world")])

    async def attachments_for_memories(self, bank_id, unit_ids, request_context, **kwargs):
        if self.slow == "enrich":
            await asyncio.sleep(SLOW_S)
        self.enrich_done = True
        return {}

    async def resolve_attachments(self, *args, **kwargs):
        return {}


def main() -> None:
    engine = _StubEngine()
    rec = _Recorder()
    reset_metrics_collector(rec)
    app = h.create_app(engine, initialize_memory=False)
    assert any(getattr(r, "path", None) == "/v1/default/banks/{bank_id}/memories/recall" for r in app.routes)
    c = TestClient(app, raise_server_exceptions=False)  # no `with`: lifespan (DB init) not run

    for slow in ("alias", "engine", "enrich"):
        for deadline in (DEADLINE, "0"):
            os.environ["HINDSIGHT_API_RECALL_HANDLER_TIMEOUT"] = deadline
            engine.slow, engine.engine_called, engine.enrich_done = slow, False, False
            rec.operations.clear()
            rec.http_status.clear()
            t = time.time()
            r = c.post(PATH, json=BODY)
            elapsed = time.time() - t
            time.sleep(0.3 if deadline == "0" else SLOW_S + 0.3)  # would cancelled work still finish?
            print(
                f"slow={slow:6} deadline={deadline}: status={r.status_code} in {elapsed:.2f}s "
                f"engine_called={engine.engine_called} enrich_done={engine.enrich_done} "
                f"op={rec.operations} http={rec.http_status}"
            )
            if deadline == "0":
                assert r.status_code == 200, (slow, r.status_code, r.text)
                assert r.json()["results"][0]["text"] == "the thermostat is set to 21C", r.text
                assert rec.http_status == [200], rec.http_status
                continue
            assert r.status_code == 504, (slow, r.status_code, r.text)
            assert r.json() == {"detail": h._RECALL_DEADLINE_DETAIL}, r.text
            assert elapsed < float(DEADLINE) + 0.5, f"{slow}: 504 took {elapsed:.2f}s"
            assert rec.http_status == [504], (slow, rec.http_status)
            assert not engine.enrich_done, f"{slow}: work continued after the deadline"
            if slow == "alias":
                assert not engine.engine_called, "engine ran after the deadline expired in alias resolution"
            if slow == "engine":
                assert rec.operations == [False], f"engine-deadline 504 recorded as {rec.operations}"
    reset_metrics_collector()
    print("RECALL DEADLINE OK")


async def _free_permits(sem: asyncio.Semaphore, n: int) -> None:
    """All n permits must be acquirable right now, i.e. none leaked."""
    got = 0
    try:
        for _ in range(n):
            await asyncio.wait_for(sem.acquire(), timeout=0.2)
            got += 1
    except (asyncio.TimeoutError, TimeoutError):
        raise AssertionError(f"admission permit leaked: only {got}/{n} acquirable") from None
    finally:
        for _ in range(got):
            sem.release()


async def check_admission_helper() -> None:
    # Cancelled while queued behind an occupant, then the occupant leaves.
    sem = asyncio.Semaphore(1)
    await sem.acquire()
    waiter = asyncio.create_task(_acquire_unless_abandoned(sem, 30.0, CancellationToken()))
    await asyncio.sleep(0.05)
    waiter.cancel()
    await asyncio.gather(waiter, return_exceptions=True)
    sem.release()
    await asyncio.sleep(0.05)
    await _free_permits(sem, 1)
    # Cancelled in the same tick the permit is granted.
    sem = asyncio.Semaphore(1)
    await sem.acquire()
    waiter = asyncio.create_task(_acquire_unless_abandoned(sem, 30.0, CancellationToken()))
    await asyncio.sleep(0.05)
    sem.release()
    waiter.cancel()
    await asyncio.gather(waiter, return_exceptions=True)
    await asyncio.sleep(0.05)
    await _free_permits(sem, 1)
    print("admission helper: no permit leaked on cancellation")


async def check_admission_end_to_end() -> None:
    import httpx

    os.environ["HINDSIGHT_API_ADMISSION_RECALL_MAX_IN_FLIGHT"] = "1"
    os.environ["HINDSIGHT_API_ADMISSION_RECALL_MAX_WAIT_MS"] = "3000"
    clear_config_cache()
    try:
        engine = _StubEngine()
        app = h.create_app(engine, initialize_memory=False)
        sem = app.state.admission._semaphores["recall"]
        await sem.acquire()  # an in-flight recall occupies the only permit
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://smoke") as cl:
            os.environ["HINDSIGHT_API_RECALL_HANDLER_TIMEOUT"] = DEADLINE
            r = await cl.post(PATH, json=BODY)  # queues in admission; deadline fires there
            assert r.status_code == 504, (r.status_code, r.text)
            assert not engine.engine_called, "engine ran although admission never granted a permit"
            sem.release()  # the occupant finishes
            await asyncio.sleep(0.1)
            os.environ["HINDSIGHT_API_RECALL_HANDLER_TIMEOUT"] = "5"
            t = time.time()
            r = await cl.post(PATH, json=BODY)
            elapsed = time.time() - t
        print(f"admission e2e: queued request 504, next request {r.status_code} in {elapsed:.2f}s")
        assert r.status_code == 200 and elapsed < 1.0, f"lane lost capacity: {r.status_code} after {elapsed:.2f}s"
        await _free_permits(sem, 1)
    finally:
        for var in ("HINDSIGHT_API_ADMISSION_RECALL_MAX_IN_FLIGHT", "HINDSIGHT_API_ADMISSION_RECALL_MAX_WAIT_MS"):
            os.environ.pop(var, None)
        clear_config_cache()


main()
asyncio.run(check_admission_helper())
asyncio.run(check_admission_end_to_end())
print("ADMISSION CANCELLATION OK")
