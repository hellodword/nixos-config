"""Enroll a device through the temporary share, then use its identity on 8443."""

import base64
import http.client
from pathlib import Path
import plistlib
import ssl
import subprocess
import sys
import zipfile

from playwright.sync_api import sync_playwright


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(executable_path=sys.argv[1])
    # The test CA is generated at runtime; curl below verifies the downloaded identity
    # against that CA. Browser enrollment starts without an installed client identity.
    context = browser.new_context(ignore_https_errors=True, accept_downloads=True)
    page = context.new_page()
    page.goto("https://files.test:8444/")
    page.get_by_label("访问码").fill("wrong-code")
    page.get_by_role("button", name="打开分享").click()
    page.get_by_role("status").filter(has_text="访问码不正确").wait_for()
    page.get_by_label("访问码").fill("Enrollment-42")
    with page.expect_download() as transfer:
        page.get_by_role("button", name="打开分享").click()
    download = transfer.value
    assert download.suggested_filename == "phone.zip", download.suggested_filename
    download.save_as("/tmp/phone.zip")
    cookies = [cookie for cookie in context.cookies() if cookie["name"] == "site_share"]
    assert len(cookies) == 1 and cookies[0]["secure"] and cookies[0]["httpOnly"], cookies
    browser.close()

with zipfile.ZipFile("/tmp/phone.zip") as bundle:
    profile = plistlib.loads(bundle.read("phone.mobileconfig"))
    identities = [item for item in profile["PayloadContent"] if item["PayloadType"] == "com.apple.security.pkcs12"]
    assert len(identities) == 1 and "Password" not in identities[0]
    assert identities[0]["PayloadContent"] == bundle.read("phone.p12")
    Path("/tmp/phone.p12").write_bytes(bundle.read("phone.p12"))
    assert bundle.read("server-ca.cer") == subprocess.check_output(
        ["openssl", "x509", "-in", "/tmp/ca.crt", "-outform", "DER"])

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
