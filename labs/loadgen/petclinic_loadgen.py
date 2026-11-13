#!/usr/bin/env python3
"""Always-on browser load generator for Splunk RUM + backend traffic.

Runs inside the cluster as its own Deployment, hitting api-gateway's
ClusterIP Service directly (not the NodePort/Ingress paths built for human
access). Adapted from ~/k8s_workshop/petclinic_browser_test.py (the proven
AW2 Section 7 RUM mechanism) with two differences:

  1. Loops forever (SIGTERM-aware) with a short pause between iterations,
     instead of a fixed --iterations/--duration count.
  2. Runs N browser contexts concurrently within ONE Chromium process
     (async API), to approximate JMeter's -Jthreads=5 without paying for
     several separate browser processes.

Same route/quirk notes as the source script apply here unchanged: hash-based
ui-router routes (#!/owners/details/<id>, NOT #!/owners/<id>), telephone must
be exactly 12 digits, the visit textarea has no name/id so it's found by
position, and the owner-edit redirect lands after networkidle fires so it is
waited for explicitly rather than assumed.
"""
import argparse
import asyncio
import contextlib
import logging
import os
import random
import signal
import time

from playwright.async_api import async_playwright, TimeoutError as PWTimeout

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s")

OWNER_PETS = [(1, 1), (2, 2), (3, 3), (3, 4), (4, 5), (5, 6),
              (6, 7), (6, 8), (7, 9), (8, 10), (9, 11), (10, 12), (10, 13)]
PHONES = ["608555102312", "608555284712", "608555918212", "608555336512"]

shutdown = asyncio.Event()


async def journey(page, base, n):
    """One pass through the app: browse, edit an owner, add a visit."""
    owner_id, pet_id = OWNER_PETS[n % len(OWNER_PETS)]

    await page.goto(f"{base}/", wait_until="networkidle")
    await page.wait_for_timeout(1000)

    await page.goto(f"{base}/#!/owners", wait_until="networkidle")
    await page.goto(f"{base}/#!/vets", wait_until="networkidle")
    # AngularJS caches the vets list in a JS-heap-resident $http promise for
    # the life of the running app instance. Each worker below reuses one
    # page/context for its entire lifetime (never a fresh page per
    # iteration), so a plain goto("#!/vets") only ever fetches it once per
    # worker, not once per iteration — confirmed live 2026-09-03: vets-service
    # was seeing ~5% of its total request volume actually touch the
    # database, vs. ~60-90% for customers-service/visits-service, whose
    # routes are per-record CRUD and can't be cached away the same way. A
    # full page.reload() re-bootstraps Angular from scratch, clearing that
    # cache. Every 4th iteration, not every one — a real reload costs its own
    # networkidle round-trip, and the point of dialing CONCURRENCY back was
    # to reduce sustained load, not quietly restore it via a different route.
    if n % 4 == 0:
        await page.reload(wait_until="networkidle")
    await page.goto(f"{base}/#!/owners/details/{owner_id}", wait_until="networkidle")

    # Write path 1: edit the owner, real PUT via form submit.
    await page.goto(f"{base}/#!/owners/{owner_id}/edit", wait_until="networkidle")
    try:
        await page.fill("input[name=telephone]", random.choice(PHONES))
        await page.click("button[type=submit]")
        await page.wait_for_url(f"**/#!/owners/details/{owner_id}", timeout=5000)
    except PWTimeout:
        logging.warning("[%s] owner form timed out — continuing", n)

    # Write path 2: add a visit for the pet, real POST via form submit.
    await page.goto(f"{base}/#!/owners/{owner_id}/pets/{pet_id}/visits",
                     wait_until="networkidle")
    try:
        await page.fill("form textarea", f"Routine checkup, visit {n}")
        await page.click("form button[type=submit]")
        await page.wait_for_load_state("networkidle")
    except PWTimeout:
        logging.warning("[%s] visit form timed out — continuing", n)


async def worker(worker_id, browser, base, pause_min, pause_max, stats):
    log = logging.getLogger(f"worker-{worker_id}")
    context = await browser.new_context(viewport={"width": 1440, "height": 900})
    page = await context.new_page()
    n = 0
    try:
        while not shutdown.is_set():
            try:
                await journey(page, base, n)
                stats["ok"] += 1
            except Exception as exc:  # noqa: BLE001 — keep the loop alive
                stats["err"] += 1
                log.warning("iteration %s failed: %s", n, exc)
            n += 1
            if n % 10 == 0:
                log.info("completed %s iterations (ok=%s err=%s total)",
                          n, stats["ok"], stats["err"])
            pause = random.uniform(pause_min, pause_max)
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(shutdown.wait(), timeout=pause)
    finally:
        await context.close()
        log.info("stopped after %s iterations", n)


def install_signal_handlers(loop):
    def _handler(signame):
        logging.getLogger("main").info("received %s — finishing in-flight iterations "
                                         "and shutting down", signame)
        shutdown.set()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _handler, sig.name)


async def main_async(args):
    log = logging.getLogger("main")
    log.info("target=%s concurrency=%s pause=%s-%ss",
              args.url, args.concurrency, args.pause_min, args.pause_max)
    stats = {"ok": 0, "err": 0}
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        loop = asyncio.get_running_loop()
        install_signal_handlers(loop)
        started = time.time()
        workers = [
            asyncio.create_task(worker(i, browser, args.url, args.pause_min,
                                        args.pause_max, stats))
            for i in range(args.concurrency)
        ]
        await shutdown.wait()
        await asyncio.gather(*workers)
        await browser.close()
    elapsed = time.time() - started
    log.info("shut down after %.0fs — ok=%s err=%s total=%s",
              elapsed, stats["ok"], stats["err"], stats["ok"] + stats["err"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get(
        "PETCLINIC_URL",
        "http://wsuser01-petclinic-srv.petclinic.svc.cluster.local:8080"))
    ap.add_argument("--concurrency", type=int,
                     default=int(os.environ.get("CONCURRENCY", "5")))
    ap.add_argument("--pause-min", type=float,
                     default=float(os.environ.get("PAUSE_MIN", "2")))
    ap.add_argument("--pause-max", type=float,
                     default=float(os.environ.get("PAUSE_MAX", "5")))
    args = ap.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
