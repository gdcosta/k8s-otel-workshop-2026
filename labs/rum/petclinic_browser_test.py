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

    --headed   watch it run (needs a display; normally leave it off)
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://minikube:30000")
    ap.add_argument("--iterations", type=int, default=5)
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()

    print(f"RUM browser test -> {args.url}   ({args.iterations} iterations)")
    started = time.time()

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        # A fresh context per run gives RUM a clean session rather than one
        # long-running visit.
        context = browser.new_context(viewport={"width": 1440, "height": 900})
        page = context.new_page()

        page.goto(f"{args.url}/", wait_until="networkidle")
        if not page.evaluate("typeof SplunkRum !== 'undefined'"):
            print("  ✗ SplunkRum is NOT defined — the RUM snippet is not being served.")
            print("    Check the <head> of the page source before going further.")
            browser.close()
            return 1
        print("  ✓ SplunkRum is initialised in the browser")

        for i in range(args.iterations):
            journey(page, args.url, i)
            print(f"  iteration {i + 1}/{args.iterations} complete")

        # Give the last beacons time to leave before tearing the browser down.
        page.wait_for_timeout(4000)
        browser.close()

    print(f"Done in {time.time() - started:.0f}s. "
          f"RUM data appears in Observability Cloud within a minute or two.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
