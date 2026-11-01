#!/usr/bin/env python3
"""Authenticated smoke tests for the Moodle container."""

import http.cookiejar
import os
import re
import sys
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlparse
from urllib.request import HTTPCookieProcessor, Request, build_opener


BASE_URL = "http://app:8080/"
USERNAME = os.environ.get("MOODLE_USERNAME", "moodleuser")
PASSWORD = os.environ.get("MOODLE_PASSWORD", "PLEASE_CHANGEME")

# These plugins are installed by download-moodle-code in every image.
IMAGE_INSTALLED_PLUGINS = (
    "cachestore_redissentinel",
    "cachestore_memcached",
)
OPTIONAL_TEST_PLUGIN = "report_benchmark"

ERROR_PATTERNS = (
    r"Exception\s*-",
    r"Coding error detected",
    r"Fatal error",
    r"Parse error",
    r"Debug info:",
    r"Stack trace:",
    r"Error writing to database",
)


class LoginTokenParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.login_token = None

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "input":
            return
        attributes = dict(attrs)
        if attributes.get("name") == "logintoken":
            self.login_token = attributes.get("value")


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def request(opener, path, data=None):
    url = urljoin(BASE_URL, path)
    body = urlencode(data).encode() if data is not None else None
    req = Request(url, data=body, headers={"User-Agent": "alpine-moodle-ci/1.0"})
    try:
        response = opener.open(req, timeout=30)
        return response.getcode(), response.geturl(), response.read().decode("utf-8", "replace")
    except HTTPError as error:
        return error.code, error.geturl(), error.read().decode("utf-8", "replace")
    except (URLError, TimeoutError) as error:
        fail(f"Request to {path} failed: {error}")


def ensure_no_moodle_error(page, path):
    for pattern in ERROR_PATTERNS:
        if re.search(pattern, page, re.IGNORECASE):
            fail(f"{path} returned Moodle/PHP error output matching {pattern!r}")


def main():
    opener = build_opener(HTTPCookieProcessor(http.cookiejar.CookieJar()))

    print("Test: authenticate to Moodle")
    status, _, login_page = request(opener, "login/index.php")
    if status != 200:
        fail(f"Login page returned HTTP {status}")

    token_parser = LoginTokenParser()
    token_parser.feed(login_page)
    if not token_parser.login_token:
        fail("Moodle login page did not provide a logintoken")

    status, final_url, login_result = request(
        opener,
        "login/index.php",
        {
            "username": USERNAME,
            "password": PASSWORD,
            "logintoken": token_parser.login_token,
            "loginbutton": "Log in",
        },
    )
    if status != 200 or urlparse(final_url).path.startswith("/login/"):
        fail("Login was not successful; Moodle redirected back to the login page")
    ensure_no_moodle_error(login_result, "/login/index.php")
    print("PASS: Moodle login succeeded")

    print("Test: access Moodle administration")
    status, admin_url, admin_page = request(opener, "admin/index.php")
    if status != 200 or urlparse(admin_url).path.startswith("/login/"):
        fail(f"Could not access /admin/index.php (HTTP {status}, final URL {admin_url})")
    ensure_no_moodle_error(admin_page, "/admin/index.php")
    if "Site administration" not in admin_page and "Notifications" not in admin_page:
        fail("Admin page did not contain the expected administration content")
    print("PASS: authenticated administrator can access /admin/index.php")

    print("Test: enumerate image-installed plugins")
    status, plugins_url, plugins_page = request(opener, "admin/plugins.php")
    if status != 200 or urlparse(plugins_url).path.startswith("/login/"):
        fail(f"Could not access /admin/plugins.php (HTTP {status})")
    ensure_no_moodle_error(plugins_page, "/admin/plugins.php")

    installed = [
        component
        for component in IMAGE_INSTALLED_PLUGINS
        if re.search(r"(?<![A-Za-z0-9_])" + re.escape(component) + r"(?![A-Za-z0-9_])", plugins_page)
    ]
    print("Image-installed plugins:")
    for component in installed:
        print(f"  - {component}")

    missing = sorted(set(IMAGE_INSTALLED_PLUGINS) - set(installed))
    if missing:
        fail("Expected image-installed plugin(s) missing from Moodle plugin overview: " + ", ".join(missing))
    print("PASS: all image-installed plugins are listed")

    # report_benchmark is added only in the dedicated plugin-install build.
    # Later update and bind-volume test variants intentionally use images without it.
    if re.search(
        r"(?<![A-Za-z0-9_])" + re.escape(OPTIONAL_TEST_PLUGIN) + r"(?![A-Za-z0-9_])",
        plugins_page,
    ):
        print("Test: open report_benchmark")
        status, report_url, report_page = request(opener, "report/benchmark/index.php")
        if status != 200 or urlparse(report_url).path.startswith("/login/"):
            fail(f"Could not open report_benchmark (HTTP {status}, final URL {report_url})")
        ensure_no_moodle_error(report_page, "/report/benchmark/index.php")
        if "benchmark" not in report_page.lower():
            fail("Benchmark report page did not contain expected benchmark content")
        print("PASS: report_benchmark opened without Moodle/PHP errors")
    else:
        print("SKIP: report_benchmark is not installed in this test image")


if __name__ == "__main__":
    main()
