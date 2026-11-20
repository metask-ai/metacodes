"""The runtime of a running Bench service, reached over its HTTP API.

`Client` answers the same questions as a local `Workbench`; the CLI uses it
for a service it started or one on another machine (`--url`).
"""
from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


class Client:
    def __init__(self, url, api_url=None, legacy_token=""):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("工作台地址必须是 http(s) URL")
        self.url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/") + "/", "", ""))
        self.api_url = api_url or self.url
        # Only for a service started before the login was dropped, read from
        # this machine's private receipt: it is needed to stop that service.
        self.legacy_token = legacy_token

    def request(self, path, payload=None):
        headers = {"Accept": "application/json"}
        if self.legacy_token:
            headers["Authorization"] = "Bearer " + self.legacy_token
        body = None
        if payload is not None:
            body = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(urllib.parse.urljoin(self.api_url, path), data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            try:
                message = json.load(exc).get("error", str(exc.code))
            except (ValueError, AttributeError):
                message = str(exc.code)
            finally:
                exc.close()
            raise ValueError(message) from None

    def open_url(self):
        return self.url
