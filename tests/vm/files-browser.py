"""Fetch a profile through browser navigation, then use its identity on 8443."""

import base64
import http.client
from pathlib import Path
import plistlib
import ssl
import subprocess
import sys

from playwright.sync_api import expect, sync_playwright


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(executable_path=sys.argv[1])
    # The test CA is generated at runtime; curl below verifies the downloaded identity
    # against that CA. Browser enrollment starts without an installed client identity.
    context = browser.new_context(ignore_https_errors=True, accept_downloads=True)
    page = context.new_page()
    page.goto("https://files.test:8444/")
    code = page.get_by_label("访问码")
    expect(code).to_have_attribute("type", "text")
    code.fill("wrong-code")
    page.get_by_role("button", name="打开分享").click()
    page.get_by_role("status").filter(has_text="访问码不正确").wait_for()
    access_code = sys.argv[2]
    code.fill(access_code.lower())
    expect(code).to_have_value(access_code)
    code.fill("")
    code.press_sequentially(access_code.replace("-", "").lower())
    expect(code).to_have_value(access_code)
    # Editing across a separator removes the adjacent character in one keystroke.
    code.press("Home")
    for _ in range(5):
        code.press("ArrowRight")
    code.press("Backspace")
    code.press(access_code[3])
    expect(code).to_have_value(access_code)
    page.get_by_role("button", name="打开分享").click()
    # Chromium verifies the HTTP handoff. The native installation prompt belongs to iOS.
    with page.expect_download() as transfer, page.expect_request("**/phone.mobileconfig") as navigation:
        page.get_by_role("link", name="phone.mobileconfig", exact=True).click()
    assert navigation.value.is_navigation_request() and navigation.value.method == "GET"
    download = transfer.value
    assert download.suggested_filename == "phone.mobileconfig", download.suggested_filename
    download.save_as("/tmp/phone.mobileconfig")
    response = context.request.get(download.url)
    assert response.status == 200, response.status
    assert response.headers["content-type"] == "application/x-apple-aspen-config", response.headers
    assert response.headers["cache-control"] == "no-store", response.headers
    assert "sandbox" not in response.headers.get("content-security-policy", ""), response.headers
    assert response.body() == Path("/tmp/phone.mobileconfig").read_bytes()
    for filename in ("phone.p12", "server-ca.cer"):
        response = context.request.get("https://files.test:8444/" + filename)
        assert response.status == 200, response.status
        Path("/tmp", filename).write_bytes(response.body())
    cookies = [cookie for cookie in context.cookies() if cookie["name"] == "site_share"]
    assert len(cookies) == 1 and cookies[0]["secure"] and cookies[0]["httpOnly"], cookies
    browser.close()

profile_bytes = Path("/tmp/phone.mobileconfig").read_bytes()
assert profile_bytes == Path("/tmp/single.mobileconfig").read_bytes()
profile = plistlib.loads(profile_bytes)
identities = [item for item in profile["PayloadContent"] if item["PayloadType"] == "com.apple.security.pkcs12"]
roots = [item for item in profile["PayloadContent"] if item["PayloadType"] == "com.apple.security.root"]
assert len(identities) == 1 and "Password" not in identities[0]
assert Path("/tmp/phone.p12").read_bytes() == identities[0]["PayloadContent"]
ca = subprocess.check_output(["openssl", "x509", "-in", "/tmp/ca.crt", "-outform", "DER"])
assert len(roots) == 1 and roots[0]["PayloadContent"] == ca
assert Path("/tmp/server-ca.cer").read_bytes() == ca

result = subprocess.check_output([
    "curl", "--fail", "--silent", "--show-error", "--cacert", "/tmp/ca.crt",
    "--cert-type", "P12", "--cert", "/tmp/phone.p12:export-test-password",
    "--user", "user:changed-test-password", "https://files.test:8443/user/browser.txt",
])
assert result == b"browser upload", result

subprocess.run(["openssl", "pkcs12", "-in", "/tmp/phone.p12", "-passin", "pass:export-test-password",
                "-noenc", "-out", "/tmp/phone.pem"], check=True)
context = ssl.create_default_context(cafile="/tmp/ca.crt")
context.load_cert_chain("/tmp/phone.pem")
connection = http.client.HTTPSConnection("files.test", 8443, context=context, timeout=120)
credentials = base64.b64encode(b"user:changed-test-password").decode()
connection.request("GET", "/user/browser.txt", headers={"Authorization": "Basic " + credentials})
assert connection.getresponse().read() == b"browser upload"
Path("/tmp/device-connection-ready").touch()
# The driver revokes this identity once it observes the open authenticated connection.
try:
    assert connection.sock.recv(1) == b""
except ConnectionResetError:
    pass
finally:
    connection.close()
