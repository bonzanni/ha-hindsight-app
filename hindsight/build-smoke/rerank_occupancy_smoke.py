"""Build-time regression check for rerank-contention.patch occupancy accounting.

Runs during `docker build` against the patched LocalSTCrossEncoder (stub model,
no weights loaded). Covers the reviewer-required cases:

  1. A queued job cancelled before its thread starts must release its slot
     (the v1 worker-thread `finally` leaked here — cancellation of a queued
     concurrent future means the fn never runs; the done-callback fires for
     every terminal state including pre-start cancellation).
  2. A running job whose awaiter is cancelled must stay counted until the
     thread actually finishes (threads cannot be cancelled).
  3. A worker exception must release the slot.
  4. The counter must end at zero and never go negative.

Timing: the stub predict sleeps SLEEP_S; ticks are generous multiples to keep
this deterministic on slow builders.
"""

import asyncio
import time
from concurrent.futures import ThreadPoolExecutor

from hindsight_api.engine.cross_encoder import LocalSTCrossEncoder

SLEEP_S = 1.0
TICK_S = 0.15


class _StubModel:
    def __init__(self, fail: bool = False):
        self.fail = fail

    def predict(self, pairs, batch_size=32, show_progress_bar=False):
        time.sleep(SLEEP_S)
        if self.fail:
            raise RuntimeError("stub failure")
        return [0.0] * len(pairs)


def _encoder(fail: bool = False) -> LocalSTCrossEncoder:
    enc = LocalSTCrossEncoder.__new__(LocalSTCrossEncoder)  # skip model load
    enc._model = _StubModel(fail=fail)
    enc.bucket_batching = False
    enc.batch_size = 32
    enc.timeout = 0  # upstream wall-clock ceiling between batches; 0 disables
    enc._device_type = "cpu"
    return enc


async def main() -> None:
    LocalSTCrossEncoder._executor = ThreadPoolExecutor(
        max_workers=1, thread_name_prefix="smoke-reranker"
    )
    enc = _encoder()
    pairs = [("q", "d")]
    assert LocalSTCrossEncoder.pending_jobs() == 0

    # Case 1+2: occupy the single worker, queue a second job, cancel both.
    t1 = asyncio.create_task(enc.predict(pairs))
    await asyncio.sleep(TICK_S)  # t1 running
    t2 = asyncio.create_task(enc.predict(pairs))
    await asyncio.sleep(TICK_S)  # t2 queued behind t1
    assert LocalSTCrossEncoder.pending_jobs() == 2, LocalSTCrossEncoder.pending_jobs()

    t2.cancel()  # queued -> concurrent future cancels -> slot must release
    await asyncio.sleep(TICK_S)
    assert LocalSTCrossEncoder.pending_jobs() == 1, LocalSTCrossEncoder.pending_jobs()

    t1.cancel()  # running -> thread keeps the slot until it finishes
    await asyncio.sleep(TICK_S)
    assert LocalSTCrossEncoder.pending_jobs() == 1, LocalSTCrossEncoder.pending_jobs()
    await asyncio.sleep(SLEEP_S)  # let the doomed thread finish
    assert LocalSTCrossEncoder.pending_jobs() == 0, LocalSTCrossEncoder.pending_jobs()
    for t in (t1, t2):
        try:
            await t
        except (asyncio.CancelledError, Exception):
            pass

    # Case 3: worker exception still releases the slot.
    enc_fail = _encoder(fail=True)
    try:
        await enc_fail.predict(pairs)
        raise AssertionError("stub failure did not propagate")
    except RuntimeError:
        pass
    assert LocalSTCrossEncoder.pending_jobs() == 0, LocalSTCrossEncoder.pending_jobs()

    # Case 4: normal completion, counter at zero (never negative).
    scores = await enc.predict(pairs)
    assert scores == [0.0]
    assert LocalSTCrossEncoder.pending_jobs() == 0, LocalSTCrossEncoder.pending_jobs()

    LocalSTCrossEncoder._executor.shutdown(wait=True)
    LocalSTCrossEncoder._executor = None
    print("rerank occupancy accounting OK")


asyncio.run(main())
