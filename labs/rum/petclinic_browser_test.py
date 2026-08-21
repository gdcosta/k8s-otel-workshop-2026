#!/usr/bin/env python3
"""Browser-based load for Splunk RUM.

Replaces the JMeter WebDriver Set plan used in earlier versions of this workshop.
RUM data only exists if a *real browser* executes the page's JavaScript, so this
drives Chromium through the same journey a user would take.

Why Playwright instead of JMeter + WebDriver:
  - Browser and driver are installed as a matched pair, so there is no
    Chrome/chromedriver/Selenium version triangle to keep aligned.
  - No 111 MB custom JMeter build to host and maintain.
  - Ordinary Python, so the journey is readable and easy to extend.

Usage:
    playwright-venv/bin/python petclinic_browser_test.py \
        --url http://minikube:30000 --iterations 5

    --headed     watch it run (needs a display; normally leave it off)
    --duration   run for this many seconds instead of a fixed count — see below

A handful of iterations proves the mechanism, but it is nowhere near enough RUM
data to actually explore the Observability Cloud RUM UI: session lists, page-load
waterfalls, JS-error grouping all want more than a minute of traffic behind them.
For that, pass --duration instead of relying on the default --iterations 5:

    playwright-venv/bin/python petclinic_browser_test.py \
        --url http://minikube:30000 --duration 900     # ~15 minutes

Same "whichever comes first" rule as JMeter's -Jloops/-Jduration: if you pass
both, the run stops at whichever limit it hits first. --duration alone runs
until time is up, with no separate iteration cap to also satisfy.

Ctrl-C is caught between iterations and closes the browser before exiting,
rather than leaving a headless Chromium process behind. It is not guaranteed
instant — if the interrupt lands mid-navigation, inside Playwright's own
network wait, it finishes that step first. If you need it gone immediately,
`pkill -f petclinic_browser_test.py` is the blunt fallback.
"""
import argparse
import random
import sys
import time

from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

# Owner -> pet pairs that exist in PetClinic's seed data. Owner and pet IDs do
# NOT run in parallel: owner 3 has two pets, so everything after it is offset.
OWNER_PETS = [(1, 1), (2, 2), (3, 3), (3, 4), (4, 5), (5, 6),
              (6, 7), (6, 8), (7, 9), (8, 10), (9, 11), (10, 12), (10, 13)]

PHONES = ["6085551023", "6085552847", "6085559182", "6085553365"]
PET_SUFFIX = ["Rex", "Bella", "Milo", "Luna", "Ziggy"]


def journey(page, base, n):
    """One pass through the application, as a user would navigate it."""
    owner_id, pet_id = OWNER_PETS[n % len(OWNER_PETS)]

    # Landing page. networkidle matters: RUM initialises and sends its first
    # beacon after load, so leaving immediately loses the page-load metrics.
    page.goto(f"{base}/", wait_until="networkidle")
    page.wait_for_timeout(1500)

    page.goto(f"{base}/owners/find", wait_until="networkidle")
    page.goto(f"{base}/owners?lastName=", wait_until="networkidle")
    page.goto(f"{base}/vets.html", wait_until="networkidle")

    # Owner detail, then a real form submission — a POST is more interesting to
    # RUM and APM than another GET.
    page.goto(f"{base}/owners/{owner_id}", wait_until="networkidle")
    page.goto(f"{base}/owners/{owner_id}/edit", wait_until="networkidle")
    try:
        page.fill("#telephone", random.choice(PHONES))
        page.click("button[type=submit]")
        page.wait_for_load_state("networkidle")
    except PWTimeout:
        print(f"    [{n}] owner form timed out — continuing")

    # Rename a pet.
    page.goto(f"{base}/owners/{owner_id}/pets/{pet_id}/edit", wait_until="networkidle")
    try:
        page.fill("#name", f"{random.choice(PET_SUFFIX)}{random.randint(1, 99)}")
        page.click("button[type=submit]")
        page.wait_for_load_state("networkidle")
    except PWTimeout:
        print(f"    [{n}] pet form timed out — continuing")

    # Deliberate error. This surfaces as a front-end error in RUM, a 500 in APM,
    # and a RuntimeException stack trace in Splunk Enterprise — the same event
    # seen from three angles.
    page.goto(f"{base}/oups", wait_until="networkidle")
    page.wait_for_timeout(1000)


def report_rum_status(page, base, js_errors):
    """Confirm RUM actually initialised, and say precisely what failed if not.

    Three outcomes are genuinely different problems, and the fix for each lives
    somewhere else entirely:

      1. the snippet never reached the page      -> template edit / image / rollout
      2. the snippet is on the page but broke    -> the JavaScript in the snippet
      3. the library loaded but init() never ran -> the SplunkRum.init({...}) call

    Grepping the served HTML cannot tell these apart, which is why this check
    exists: a snippet containing invalid JavaScript (a `#` comment, a missing
    comma) is still present in the HTML, still matches every grep, and still
    collects nothing at all. Only the browser knows the difference.
    """
    loaded = page.evaluate("typeof SplunkRum !== 'undefined'")
    # Newer @splunk/otel-web sets `inited` once init() completes. If the property
    # is absent we cannot distinguish 2 from 3, so treat the library loading as
    # sufficient rather than raising a false alarm.
    inited = page.evaluate(
        "typeof SplunkRum !== 'undefined' && typeof SplunkRum.inited === 'boolean'"
        " ? SplunkRum.inited : null"
    )
    html = page.content()
    snippet_served = "SplunkRum.init" in html
    cdn_served = "o11y-gdi-rum" in html

    if loaded and inited is not False:
        print("  ✓ SplunkRum is initialised in the browser")
        return 0

    print("  ✗ RUM did NOT initialise in the browser.")

    if not cdn_served and not snippet_served:
        print("    Cause: the snippet is ABSENT from the served HTML — neither the")
        print("    o11y-gdi-rum <script> tag nor SplunkRum.init appears in the page.")
        print("    Look at how the snippet gets in: re-check the template edit, rebuild")
        print("    the image, and roll the deployment — a running pod may predate it.")
    elif not loaded:
        print("    Cause: the snippet IS in the served HTML, but the SplunkRum library")
        print("    never became available. Either the o11y-gdi-rum <script> tag did not")
        print("    load (check the CDN URL and this host's network access), or the")
        print("    inline script threw before it could run.")
        print("    The template edit and the image build are NOT the problem here — the")
        print("    snippet reached the browser.")
    else:
        print("    Cause: the snippet IS in the served HTML and the library loaded, but")
        print("    SplunkRum.init() never completed. The fault is inside the init block")
        print("    itself — NOT the template edit and NOT the image build.")
        print("    Usual culprit: invalid JavaScript inside SplunkRum.init({...}) — a")
        print("    `#` comment (JavaScript comments are `//`), a comma swallowed into")
        print("    such a comment, or an unquoted value.")

    if js_errors:
        print("    JavaScript errors raised by the page:")
        for err in js_errors:
            print(f"      {err.splitlines()[0]}")
    else:
        print("    The page raised no JavaScript errors, so nothing threw at parse time.")

    print("    Read the block back as JavaScript, not as YAML:")
    print(f"      curl -s {base}/ | sed -n '/SplunkRum.init/,/}});/p'")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://minikube:30000")
    ap.add_argument("--iterations", type=int, default=None,
                     help="number of journeys to run. Default 5, unless --duration is "
                          "given with no explicit --iterations, in which case duration "
                          "alone governs.")
    ap.add_argument("--duration", type=int, default=0,
                     help="run for this many seconds instead of (or in addition to) a "
                          "fixed --iterations count. Whichever limit is hit first stops "
                          "the run — same rule as JMeter's -Jloops/-Jduration.")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()

    if args.iterations is None:
        # --duration alone should mean "run until time is up," not "run 5 times
        # then stop early." Only fall back to the original default of 5 when
        # neither flag was given at all.
        args.iterations = 10**9 if args.duration else 5

    if args.duration:
        print(f"RUM browser test -> {args.url}   "
              f"(up to {args.duration}s, or {args.iterations} iterations, whichever first)")
    else:
        print(f"RUM browser test -> {args.url}   ({args.iterations} iterations)")
    started = time.time()

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        # A fresh context per run gives RUM a clean session rather than one
        # long-running visit.
        context = browser.new_context(viewport={"width": 1440, "height": 900})
        page = context.new_page()

        # Uncaught JavaScript errors are the evidence that separates "the snippet
        # never arrived" from "the snippet arrived and is broken". Listen before
        # the first navigation so a parse-time error is not missed.
        js_errors = []
        page.on("pageerror", lambda e: js_errors.append(str(e)))

        page.goto(f"{args.url}/", wait_until="networkidle")
        rum_status = report_rum_status(page, args.url, js_errors)
        if rum_status:
            browser.close()
            return rum_status

        completed = 0
        try:
            for i in range(args.iterations):
                if args.duration and (time.time() - started) >= args.duration:
                    break
                journey(page, args.url, i)
                completed += 1
                elapsed = time.time() - started
                if args.duration:
                    print(f"  iteration {completed} complete "
                          f"({elapsed:.0f}s / {args.duration}s)")
                else:
                    print(f"  iteration {completed}/{args.iterations} complete")
        except KeyboardInterrupt:
            print(f"\n  stopped by Ctrl-C after {completed} iterations "
                  f"({time.time() - started:.0f}s) — closing the browser cleanly")

        # Give the last beacons time to leave before tearing the browser down.
        page.wait_for_timeout(4000)
        browser.close()

    print(f"Done in {time.time() - started:.0f}s, {completed} iterations. "
          f"RUM data appears in Observability Cloud within a minute or two.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
