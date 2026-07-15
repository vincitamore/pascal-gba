"""sprite_lib.xai -- xAI Imagine API client (OAuth + refresh + prompt-cache + cost ledger).

Rides the grok-CLI OAuth token at ~/.grok/auth.json (scope `api:access`). The bearer
JWT expires every ~6h; we read the entry's `expires_at`, refresh via the OIDC
token endpoint when within 5 minutes of expiry, and write the new token back so
later sessions inherit it.

Endpoints used (per docs.x.ai, ingested 2026-05-21, shape verified live against
the grok-build OAuth token):
  POST {base}/v1/images/generations   text -> image  (model: grok-imagine-image-quality)
  POST {base}/v1/images/edits         1 ref:  image: {url, type}
                                       2-3 refs: images: [{url, type}, ...]
                                       (address as <IMAGE_0>..<IMAGE_2> in prompt)
  POST {base}/v1/videos/generations   t2v: prompt only
                                       i2v: image: {url}  (locks first frame)
                                       r2v: reference_images: [{url}, ...]
                                            (1-3 refs guide style/content)

Reference encoding: each `{url, type}` object's url can be a public HTTPS URL or
a data URI (`data:image/<jpeg|png|webp>;base64,...`). Local files are encoded
to data URI via `_data_uri_for_path`.

Response shape:
  /v1/images/*: {data: [{b64_json|url, mime_type, ...}], usage: {cost_in_usd_ticks}}
  /v1/videos/*: async -- submit returns {request_id}; poll GET /v1/videos/{rid}
                returns {status, video: {url, duration, ...}, usage: {...}}

Prompt-artifact cache: assets/.cache/<sha16>.<ext>. Keyed on (op, model, prompt,
params, ref-file-hashes). On cache hit, copy to --out and skip the API call. The
operator can blast the cache with `sprite cache clear` (handled by the umbrella).

All calls append a ledger entry (sprite_lib.cost). Errors propagate as XaiError
with HTTP status + body for the agent to inspect.
"""
from __future__ import annotations
import base64
import hashlib
import io
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

import requests

from . import cost, util


AUTH_PATH_DEFAULT = Path.home() / ".grok" / "auth.json"
BASE_URL_DEFAULT = "https://api.x.ai"
ISSUER_DEFAULT = "https://auth.x.ai"
# Documented xAI env var name (console.x.ai / docs.x.ai). Vendor secret, not a
# tool-local SPRITE_* root -- existing xAI tooling config just works.
XAI_API_KEY_ENV = "XAI_API_KEY"
# Cache dir resolved at call time relative to cwd. Run the CLI from your asset
# root. Override per-instance via the `cache_dir` ctor kwarg or CLI `--cache-dir`.
def _default_cache_dir() -> Path:
    return Path.cwd() / ".cache"
REFRESH_LEEWAY_SECONDS = 5 * 60  # refresh if token expires within 5 minutes

# No-credential message: name the env var, key console, OAuth fallback, and docs.
_NO_CREDS_MSG = (
    "no xAI credentials found. Set XAI_API_KEY (create one at "
    "https://console.x.ai/team/default/api-keys and grant it access to the "
    "images/videos endpoints + models you plan to use), or run `grok login` "
    "if you have the grok CLI and want to ride your existing subscription "
    "instead. See PIPELINE.md#authentication."
)


def _key_rejected_msg(status: int, body: str = "") -> str:
    """Standing-key / flag path: 401 and other non-2xx are terminal (no refresh)."""
    tail = f" Response body: {body[:400]}" if body else ""
    return (
        f"xAI API request failed (http={status}). If you're using a standing "
        f"XAI_API_KEY, check that the key has been granted access to this "
        f"endpoint and model at console.x.ai (keys are default-deny; see "
        f"PIPELINE.md#authentication).{tail}"
    )


class XaiError(RuntimeError):
    """API or auth failure. Carries http_status + body for diagnostics."""

    def __init__(self, msg: str, status: int = 0, body: str = "", op: str = ""):
        super().__init__(msg)
        self.status = status
        self.body = body
        self.op = op

    def __str__(self) -> str:
        head = super().__str__()
        if self.status:
            head = f"[{self.op or 'xai'}] {head} (http={self.status})"
        if self.body:
            head = f"{head}\n  body: {self.body[:500]}"
        return head


# ============================================================
# Auth: token read, expiry check, refresh, write-back
# ============================================================

def _parse_iso(ts: str) -> datetime:
    """Parse the auth.json ISO timestamp; tolerate the 9-digit-fraction RustChrono format."""
    # truncate to microseconds (6 digits) so fromisoformat is happy
    if "." in ts:
        head, tail = ts.split(".", 1)
        # tail looks like '330364700Z' or '330364700+00:00'
        suffix = ""
        for sep in ("Z", "+", "-"):
            if sep in tail and (sep != "-" or tail.index(sep) > 0):
                idx = tail.index(sep)
                suffix = tail[idx:]
                tail = tail[:idx]
                break
        frac = tail[:6]
        ts = f"{head}.{frac}{suffix}"
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def _load_auth_doc(path: Path) -> dict:
    if not path.exists():
        raise XaiError(f"auth file not found at {path}; run `grok login`", op="auth")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise XaiError(f"auth file malformed: {e}", op="auth") from e


def _pick_entry(doc: dict) -> tuple[str, dict]:
    """Pick the OIDC entry from the multi-key auth doc."""
    candidates = [
        (k, v) for k, v in doc.items()
        if isinstance(v, dict) and v.get("auth_mode") == "oidc" and v.get("refresh_token")
    ]
    if not candidates:
        raise XaiError("no OIDC entry with refresh_token in auth.json", op="auth")
    # If multiple, prefer the one furthest from expiry (or the most recently created)
    def freshness(item):
        _, v = item
        try:
            return _parse_iso(v["expires_at"]).timestamp()
        except Exception:
            return 0.0
    candidates.sort(key=freshness, reverse=True)
    return candidates[0]


def _is_expired(entry: dict, leeway: int = REFRESH_LEEWAY_SECONDS) -> bool:
    try:
        exp = _parse_iso(entry["expires_at"]).timestamp()
    except Exception:
        return True  # if we can't parse, assume expired and force refresh
    return time.time() + leeway >= exp


def _refresh(entry: dict, issuer: str) -> dict:
    """Call OIDC token endpoint with grant_type=refresh_token. Returns the new entry fields.

    Standards: RFC 6749 section 6. The xAI implementation rotates refresh_tokens
    (each refresh returns a new one) and returns expires_in seconds.
    """
    token_endpoint = f"{issuer.rstrip('/')}/oauth2/token"
    data = {
        "grant_type": "refresh_token",
        "refresh_token": entry["refresh_token"],
        "client_id": entry["oidc_client_id"],
    }
    r = requests.post(token_endpoint, data=data, timeout=30)
    if r.status_code != 200:
        raise XaiError(f"token refresh failed", status=r.status_code, body=r.text, op="refresh")
    body = r.json()
    new_entry = dict(entry)
    new_entry["key"] = body["access_token"]
    if body.get("refresh_token"):
        new_entry["refresh_token"] = body["refresh_token"]
    if body.get("expires_in"):
        exp = datetime.now(timezone.utc).timestamp() + int(body["expires_in"])
        new_entry["expires_at"] = (datetime.fromtimestamp(exp, timezone.utc)
                                   .strftime("%Y-%m-%dT%H:%M:%S.000000000Z"))
    return new_entry


def _write_auth_doc(path: Path, doc: dict) -> None:
    """Atomic write so a simultaneous reader never sees a torn file."""
    util.atomic_write(path, json.dumps(doc, indent=2))


def get_bearer(auth_path: Path | None = None, issuer: str = ISSUER_DEFAULT,
               refresh: bool = True) -> str:
    """Return a valid bearer JWT. Refreshes in-place if expired and `refresh=True`."""
    p = Path(auth_path or AUTH_PATH_DEFAULT)
    doc = _load_auth_doc(p)
    key, entry = _pick_entry(doc)
    if refresh and _is_expired(entry):
        new_entry = _refresh(entry, issuer)
        doc[key] = new_entry
        _write_auth_doc(p, doc)
        entry = new_entry
    return entry["key"]


def resolve_token(auth_path: Path | str | None = None,
                  issuer: str = ISSUER_DEFAULT,
                  api_key: str | None = None,
                  refresh: bool = True) -> tuple[str, str]:
    """Resolve a Bearer token and its source.

    Precedence: explicit ``api_key`` (flag) -> ``XAI_API_KEY`` env -> OAuth file
    via :func:`get_bearer`. Returns ``(token, source)`` where source is one of
    ``"flag"``, ``"env"``, ``"oauth"``. The 401-forced-refresh path is only
    meaningful for ``source == "oauth"``; flag/env keys have no expiry.
    """
    if api_key:
        return api_key, "flag"
    env_key = os.environ.get(XAI_API_KEY_ENV)
    if env_key:
        return env_key, "env"
    try:
        path = Path(auth_path) if auth_path is not None else None
        return get_bearer(path, issuer, refresh=refresh), "oauth"
    except XaiError as e:
        raise XaiError(_NO_CREDS_MSG, op="auth") from e


def _mock_enabled() -> bool:
    """SPRITE_MOCK=1: synthesize images offline (no network, no auth)."""
    return os.environ.get("SPRITE_MOCK", "").strip() == "1"


def _synthesize_mock_image(out: Path) -> Path:
    """Write a small Pillow PNG suitable as a GBA-pipeline stand-in."""
    from PIL import Image
    if out.suffix == "":
        out = out.with_suffix(".png")
    out.parent.mkdir(parents=True, exist_ok=True)
    # Magenta key-color field + a solid block body (readable under bake chroma).
    img = Image.new("RGBA", (32, 32), (255, 0, 255, 255))
    for y in range(8, 24):
        for x in range(8, 24):
            img.putpixel((x, y), (90, 120, 168, 255))
    img.save(out)
    return out


# ============================================================
# HTTP: generate, edit, video
# ============================================================

def _headers(token: str, extra: dict | None = None) -> dict:
    h = {"Authorization": f"Bearer {token}",
         "Accept": "application/json"}
    if extra:
        h.update(extra)
    return h


def _ext_for_mime(mime_type: str, model: str = "") -> str:
    """File extension to use for cache + outputs based on response mime_type."""
    mt = (mime_type or "").lower()
    if "png" in mt:
        return ".png"
    if "jpeg" in mt or "jpg" in mt:
        return ".jpg"
    if "mp4" in mt or "video" in mt:
        return ".mp4"
    if "webp" in mt:
        return ".webp"
    return ".mp4" if "video" in model else ".png"


def _decode_response(body: dict, out: Path, *, video: bool = False) -> tuple[Path, int | None, str]:
    """Pull the binary payload out of a generations/edits/video response, write to `out`.

    If `out` already carries an extension, it is honored as-is (so the caller can
    pin the file name). Otherwise the extension is derived from response mime_type.
    Returns (final_out_path, cost_in_usd_ticks_or_None, mime_type).
    """
    data = body.get("data") or []
    if not data:
        raise XaiError("response missing data[0]", body=json.dumps(body)[:500], op="decode")
    first = data[0]
    mime_type = first.get("mime_type", "video/mp4" if video else "")
    payload: bytes | None = None
    if "b64_json" in first and first["b64_json"]:
        payload = base64.b64decode(first["b64_json"])
    elif "url" in first and first["url"]:
        # CDN URL fallback (the investigation says inline-b64 is canonical and CDN
        # URLs sometimes 403; we still try the URL for completeness).
        r = requests.get(first["url"], timeout=120)
        if r.status_code != 200:
            raise XaiError("CDN URL fetch failed", status=r.status_code,
                           body=r.text, op="cdn-fetch")
        payload = r.content
    else:
        raise XaiError("response has neither b64_json nor url",
                       body=json.dumps(first)[:500], op="decode")
    if out.suffix == "":
        out = out.with_suffix(_ext_for_mime(mime_type, model="video" if video else ""))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(payload)
    usage = body.get("usage") or {}
    cost_ticks = usage.get("cost_in_usd_ticks", usage.get("cost_usd_ticks"))
    return out, cost_ticks, mime_type


# ----- prompt cache -----

def _cache_path(cache_dir: Path, key: str, ext: str) -> Path:
    return cache_dir / f"{key}{ext}"


def _cache_lookup(cache_dir: Path, key: str, ext: str) -> Path | None:
    p = _cache_path(cache_dir, key, ext)
    return p if p.exists() else None


def _cache_store(cache_dir: Path, key: str, ext: str, src: Path) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    dst = _cache_path(cache_dir, key, ext)
    shutil.copyfile(src, dst)
    return dst


def _cache_lookup_any(cache_dir: Path, key: str) -> Path | None:
    """Find any cached file with this key, regardless of extension.

    The xAI Imagine API returns PNG OR JPEG (mime_type in the response), so we
    don't know the extension at cache-lookup time. Scan the cache dir for any
    file whose stem matches the key.
    """
    if not cache_dir.exists():
        return None
    for p in cache_dir.iterdir():
        if p.is_file() and p.stem == key:
            return p
    return None


def _serve_from_cache(cached: Path, out: Path, ck: str, op: str,
                      extras: dict) -> dict:
    """Copy `cached` to `out` (matching extension) and return the response record."""
    if out.suffix == "":
        out = out.with_suffix(cached.suffix)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cached, out)
    rec = {"op": op, "out": str(out), "cached": True, "cache_key": ck,
           "cost_in_usd_ticks": 0, "http_status": 0}
    rec.update(extras)
    return rec


# ----- reference image encoding (per docs.x.ai) -----

def _data_uri_for_path(path: Path) -> str:
    """Encode a local image file as data:image/<mime>;base64,<b64>.

    Per docs the edits + i2v + r2v endpoints accept JPEG, PNG, or WebP.
    """
    suf = path.suffix.lower()
    if suf in (".jpg", ".jpeg"):
        mime = "image/jpeg"
    elif suf == ".png":
        mime = "image/png"
    elif suf == ".webp":
        mime = "image/webp"
    else:
        # Fallback: JPEG. The server validates the actual bytes; mime label is a hint.
        mime = "image/jpeg"
    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{b64}"


def _build_image_ref(ref: Path | str) -> dict:
    """Build a documented image dict for `image` / `images[i]` / `reference_images[i]`.

    A `ref` may be either:
      - a local file path (Path or string)            -> encoded as data URI
      - a public HTTPS URL (string http:// or https://) -> passed through verbatim
    """
    if isinstance(ref, str) and ref.startswith(("http://", "https://")):
        return {"url": ref, "type": "image_url"}
    p = Path(ref)
    return {"url": _data_uri_for_path(p), "type": "image_url"}


# ----- public API -----

# Bumped 2026-05-21 when realigning to documented field shapes. Old (shape v1)
# cache entries are kept on disk for audit but isolated from v2 lookups.
SHAPE_VERSION = 2

# Defaults per docs.x.ai recommendations (ingested 2026-05-21).
MODEL_IMAGE_DEFAULT = "grok-imagine-image-quality"  # docs: use for all new requests
MODEL_IMAGE_BUDGET = "grok-imagine-image"           # $0.02/img, cheaper iteration
MODEL_VIDEO_DEFAULT = "grok-imagine-video"


class XaiClient:
    """Thin xAI Imagine client. One instance per process; reuses connection pooling.

    Endpoints (per docs.x.ai, verified 2026-05-21 against grok-build OAuth token):
      POST /v1/images/generations  -- text -> image
      POST /v1/images/edits        -- 1 ref: payload["image"]={url,type}
                                       2-3 refs: payload["images"]=[{url,type},...]
                                       (address refs as <IMAGE_0>..<IMAGE_2> in prompt)
      POST /v1/videos/generations  -- t2v: prompt only
                                       i2v: payload["image"]={url} (starting frame)
                                       r2v: payload["reference_images"]=[{url},...]
                                       (1-3 refs, guide without locking first frame)
    """

    def __init__(self,
                 auth_path: Path | None = None,
                 base_url: str = BASE_URL_DEFAULT,
                 issuer: str = ISSUER_DEFAULT,
                 cache_dir: Path | None = None,
                 ledger: Path | None = None,
                 timeout: int = 120,
                 retry: int = 3,
                 retry_base_delay: float = 2.0,
                 retry_max_delay: float = 30.0,
                 progress_log=None,
                 api_key: str | None = None):
        self.auth_path = Path(auth_path or AUTH_PATH_DEFAULT)
        self.base = base_url.rstrip("/")
        self.issuer = issuer
        self.cache_dir = Path(cache_dir) if cache_dir else _default_cache_dir()
        self.ledger = ledger
        self.timeout = timeout
        self.retry = max(0, retry)
        self.retry_base_delay = retry_base_delay
        self.retry_max_delay = retry_max_delay
        self.progress_log = progress_log
        # Explicit key (CLI --api-key) beats env + OAuth; None defers to resolve_token.
        self.api_key = api_key
        self._session = requests.Session()

    # -- core post with auto-refresh-on-401 and exponential-backoff retry --

    _RETRY_STATUSES = (500, 502, 503, 504)

    def _retry_delay(self, attempt: int) -> float:
        """Exponential backoff: base * 2^(attempt-1), capped at max_delay.
        attempt is 1-indexed (first retry = attempt 1)."""
        return min(self.retry_max_delay,
                   self.retry_base_delay * (2 ** max(0, attempt - 1)))

    def _log(self, msg: str) -> None:
        if self.progress_log:
            self.progress_log(msg)

    def _post_json(self, path: str, payload: dict, op: str) -> dict:
        url = f"{self.base}{path}"
        last_err: XaiError | None = None
        refreshed_once = False
        # attempt 0 is the initial; 1..retry are the exponential-backoff retries
        for attempt in range(self.retry + 1):
            if attempt > 0:
                delay = self._retry_delay(attempt)
                self._log(f"{op} retry {attempt}/{self.retry} after {delay:.1f}s "
                          f"(last status: {getattr(last_err, 'status', '?')})")
                time.sleep(delay)
            token, source = resolve_token(self.auth_path, self.issuer,
                                          self.api_key, refresh=True)
            try:
                r = self._session.post(url, json=payload, headers=_headers(token),
                                       timeout=self.timeout)
            except (requests.ConnectionError, requests.Timeout) as e:
                last_err = XaiError(f"{op} transport error: {e}", op=op)
                continue
            if r.status_code == 401 and not refreshed_once:
                # Flag/env keys have no refresh path -- 401 is terminal (bad key
                # or missing endpoint/model ACL grant at console.x.ai).
                if source != "oauth":
                    raise XaiError(_key_rejected_msg(r.status_code, r.text),
                                   status=r.status_code, body=r.text, op=op)
                # OAuth only: force a token refresh and retry WITHOUT consuming
                # retry budget (mutate expires_at so get_bearer refreshes).
                refreshed_once = True
                doc = _load_auth_doc(self.auth_path)
                key, entry = _pick_entry(doc)
                entry["expires_at"] = "1970-01-01T00:00:00.000000000Z"
                doc[key] = entry
                _write_auth_doc(self.auth_path, doc)
                token, source = resolve_token(self.auth_path, self.issuer,
                                              self.api_key, refresh=True)
                try:
                    r = self._session.post(url, json=payload, headers=_headers(token),
                                           timeout=self.timeout)
                except (requests.ConnectionError, requests.Timeout) as e:
                    last_err = XaiError(f"{op} transport error post-refresh: {e}", op=op)
                    continue
            if r.status_code in self._RETRY_STATUSES:
                last_err = XaiError(f"{op} server error", status=r.status_code,
                                    body=r.text[:500], op=op)
                continue
            if r.status_code != 200:
                # Non-retryable 4xx (other than the refreshed 401): raise immediately.
                # Standing keys: surface the default-deny ACL grant hint.
                if source in ("flag", "env"):
                    raise XaiError(_key_rejected_msg(r.status_code, r.text),
                                   status=r.status_code, body=r.text, op=op)
                raise XaiError(f"{op} request failed", status=r.status_code,
                               body=r.text, op=op)
            return r.json()
        if last_err is not None:
            raise last_err
        raise XaiError(f"{op} request failed after {self.retry + 1} attempts",
                       status=0, op=op)

    # -- text -> image --

    def generate_image(self,
                       prompt: str,
                       out: Path | str,
                       *,
                       model: str = MODEL_IMAGE_DEFAULT,
                       resolution: str = "1k",
                       aspect_ratio: str = "1:1",
                       response_format: str = "b64_json",
                       no_cache: bool = False) -> dict:
        """Text -> image via POST /v1/images/generations.

        Per docs: resolution in {1k, 2k}; aspect_ratio in {1:1, 3:4, 4:3, 9:16,
        16:9, 2:3, 3:2, 9:19.5, 19.5:9, 9:20, 20:9, 1:2, 2:1, auto}.
        """
        out = Path(out)
        ck = util.stable_hash({
            "shape_version": SHAPE_VERSION,
            "op": "generate_image", "model": model, "prompt": prompt,
            "resolution": resolution, "aspect_ratio": aspect_ratio,
        })
        cached = None if no_cache else _cache_lookup_any(self.cache_dir, ck)
        if cached:
            return _serve_from_cache(cached, out, ck, op="generate_image",
                                     extras={"model": model, "prompt": prompt})
        if _mock_enabled():
            # Offline stand-in: no network, no auth; covers write + cache + ledger.
            out_path = _synthesize_mock_image(out)
            _cache_store(self.cache_dir, ck, out_path.suffix, out_path)
            rec = {"op": "generate_image-mock", "model": model, "prompt": prompt,
                   "params": {"resolution": resolution, "aspect_ratio": aspect_ratio},
                   "mime_type": "image/png", "out": str(out_path), "cache_key": ck,
                   "cached": False, "http_status": 0, "cost_in_usd_ticks": 0}
            cost.append(rec, self.ledger)
            return rec
        payload = {
            "model": model, "prompt": prompt, "n": 1,
            "aspect_ratio": aspect_ratio, "resolution": resolution,
            "response_format": response_format,
        }
        body = self._post_json("/v1/images/generations", payload, op="generate_image")
        out_path, cost_ticks, mime = _decode_response(body, out)
        _cache_store(self.cache_dir, ck, out_path.suffix, out_path)
        rec = {"op": "generate_image", "model": model, "prompt": prompt,
               "params": {"resolution": resolution, "aspect_ratio": aspect_ratio},
               "mime_type": mime, "out": str(out_path), "cache_key": ck,
               "cached": False, "http_status": 200, "cost_in_usd_ticks": cost_ticks}
        cost.append(rec, self.ledger)
        return rec

    # -- refs + prompt -> image (single or multi) --

    def edit_image(self,
                   prompt: str,
                   refs: Sequence[Path | str],
                   out: Path | str,
                   *,
                   model: str = MODEL_IMAGE_DEFAULT,
                   resolution: str = "1k",
                   aspect_ratio: str | None = None,
                   response_format: str = "b64_json",
                   no_cache: bool = False) -> dict:
        """Refs + prompt -> image via POST /v1/images/edits.

        - 1 ref:    payload["image"]  = {url, type}
        - 2-3 refs: payload["images"] = [{url, type}, ...]
                    Address refs as <IMAGE_0>, <IMAGE_1>, <IMAGE_2> in the prompt.

        Refs may be local paths (data-URI encoded) or public HTTPS URLs.

        `aspect_ratio=None` (default) lets the server use the first ref's ratio.
        Set explicitly to override (only meaningful for multi-image edit per docs).
        """
        if len(refs) < 1:
            raise XaiError("edit_image needs >=1 ref", op="edit_image")
        if len(refs) > 3:
            raise XaiError(f"edit_image accepts up to 3 refs, got {len(refs)}",
                           op="edit_image")
        out = Path(out)
        ref_keys: list[str] = []
        for r in refs:
            if isinstance(r, str) and r.startswith(("http://", "https://")):
                ref_keys.append(f"url:{r}")
            else:
                ref_keys.append(f"sha:{util.file_sha(Path(r))}")
        ck = util.stable_hash({
            "shape_version": SHAPE_VERSION,
            "op": "edit_image", "model": model, "prompt": prompt,
            "resolution": resolution, "aspect_ratio": aspect_ratio,
            "ref_keys": ref_keys,
        })
        cached = None if no_cache else _cache_lookup_any(self.cache_dir, ck)
        if cached:
            return _serve_from_cache(cached, out, ck, op="edit_image",
                                     extras={"model": model, "prompt": prompt,
                                             "refs": [str(r) for r in refs]})
        if _mock_enabled():
            out_path = _synthesize_mock_image(out)
            _cache_store(self.cache_dir, ck, out_path.suffix, out_path)
            rec = {"op": "edit_image-mock", "model": model, "prompt": prompt,
                   "refs": [str(r) for r in refs], "ref_keys": ref_keys,
                   "params": {"resolution": resolution, "aspect_ratio": aspect_ratio},
                   "mime_type": "image/png", "out": str(out_path), "cache_key": ck,
                   "cached": False, "http_status": 0, "cost_in_usd_ticks": 0}
            cost.append(rec, self.ledger)
            return rec
        payload: dict = {
            "model": model, "prompt": prompt,
            "resolution": resolution,
            "response_format": response_format,
        }
        if aspect_ratio is not None:
            payload["aspect_ratio"] = aspect_ratio
        if len(refs) == 1:
            payload["image"] = _build_image_ref(refs[0])
        else:
            payload["images"] = [_build_image_ref(r) for r in refs]
        body = self._post_json("/v1/images/edits", payload, op="edit_image")
        out_path, cost_ticks, mime = _decode_response(body, out)
        _cache_store(self.cache_dir, ck, out_path.suffix, out_path)
        rec = {"op": "edit_image", "model": model, "prompt": prompt,
               "refs": [str(r) for r in refs], "ref_keys": ref_keys,
               "params": {"resolution": resolution, "aspect_ratio": aspect_ratio},
               "mime_type": mime, "out": str(out_path), "cache_key": ck,
               "cached": False, "http_status": 200, "cost_in_usd_ticks": cost_ticks}
        cost.append(rec, self.ledger)
        return rec

    # -- video: t2v | i2v | r2v --

    def generate_video(self,
                       prompt: str,
                       out: Path | str,
                       *,
                       mode: str = "t2v",
                       start_frame: Path | str | None = None,
                       references: Sequence[Path | str] = (),
                       model: str = MODEL_VIDEO_DEFAULT,
                       duration: int = 8,
                       aspect_ratio: str = "1:1",
                       resolution: str = "720p",
                       no_cache: bool = False,
                       poll_interval: float = 5.0,
                       poll_timeout: float = 600.0,
                       progress_log=None) -> dict:
        """Text/image/refs -> mp4 video via POST /v1/videos/generations (async).

        Modes (per docs):
          - "t2v" text-to-video      : prompt only (no `image`, no `reference_images`).
          - "i2v" image-to-video     : `start_frame` becomes the FIRST FRAME.
                                       Sends payload["image"] = {url, type}.
          - "r2v" reference-to-video : `references` (1-3) guide STYLE/CONTENT
                                       without locking the first frame.
                                       Sends payload["reference_images"] = [{url}, ...].

        Per docs: duration in [1, 15] (default 8); aspect_ratio in {1:1, 16:9,
        9:16, 4:3, 3:4, 3:2, 2:3}; resolution in {480p, 720p, 1080p}.
        """
        if mode not in ("t2v", "i2v", "r2v"):
            raise XaiError(f"unknown video mode {mode!r}; expected t2v|i2v|r2v",
                           op="generate_video")
        if mode == "i2v" and not start_frame:
            raise XaiError("mode=i2v requires start_frame", op="generate_video")
        if mode == "r2v":
            if not references:
                raise XaiError("mode=r2v requires >=1 reference", op="generate_video")
            if len(references) > 3:
                raise XaiError(f"mode=r2v accepts up to 3 refs, got {len(references)}",
                               op="generate_video")
        if mode == "t2v" and (start_frame or references):
            raise XaiError("mode=t2v takes no start_frame/references; use i2v or r2v",
                           op="generate_video")

        out = Path(out)

        def _key_for(r):
            if isinstance(r, str) and r.startswith(("http://", "https://")):
                return f"url:{r}"
            return f"sha:{util.file_sha(Path(r))}"
        start_key = _key_for(start_frame) if start_frame else None
        ref_keys = [_key_for(r) for r in references]

        ck = util.stable_hash({
            "shape_version": SHAPE_VERSION,
            "op": "generate_video", "mode": mode, "model": model, "prompt": prompt,
            "duration": duration, "aspect_ratio": aspect_ratio,
            "resolution": resolution,
            "start_key": start_key, "ref_keys": ref_keys,
        })
        cached = None if no_cache else _cache_lookup_any(self.cache_dir, ck)
        if cached:
            return _serve_from_cache(cached, out, ck, op="generate_video",
                                     extras={"model": model, "prompt": prompt,
                                             "mode": mode,
                                             "start_frame": str(start_frame) if start_frame else None,
                                             "references": [str(r) for r in references]})

        if _mock_enabled():
            raise XaiError(
                "SPRITE_MOCK does not support video generation "
                "(images only; use a real credential for video)",
                op="generate_video")

        payload: dict = {
            "model": model, "prompt": prompt,
            "duration": duration, "aspect_ratio": aspect_ratio,
            "resolution": resolution,
        }
        if mode == "i2v":
            payload["image"] = _build_image_ref(start_frame)
        elif mode == "r2v":
            payload["reference_images"] = [_build_image_ref(r) for r in references]

        submit_body = self._post_json("/v1/videos/generations", payload,
                                      op="generate_video")
        rid = submit_body.get("request_id")
        if not rid:
            raise XaiError("video submit returned no request_id",
                           body=json.dumps(submit_body)[:300], op="generate_video")

        # Poll for completion. The endpoint may return 202 (pending) or 200 with
        # a status field; handle both shapes.
        deadline = time.time() + poll_timeout
        last_progress = -1
        poll_url = f"{self.base}/v1/videos/{rid}"
        token, source = resolve_token(self.auth_path, self.issuer,
                                      self.api_key, refresh=True)
        done_body: dict | None = None
        while time.time() < deadline:
            r = self._session.get(poll_url, headers=_headers(token), timeout=30)
            if r.status_code == 200:
                rb = r.json()
                status = rb.get("status")
                if status in (None, "done"):
                    done_body = rb
                    break
                if status in ("failed", "expired"):
                    err = rb.get("error") or {}
                    raise XaiError(f"video generation {status}: "
                                   f"{err.get('message', 'no detail')}",
                                   status=0, op="generate_video",
                                   body=json.dumps(rb)[:500])
                # status=pending in a 200 -> keep polling
                p = rb.get("progress", 0)
                if p != last_progress:
                    last_progress = p
                    if progress_log:
                        progress_log(f"video {rid[:8]}: {status} {p}%")
                time.sleep(poll_interval)
                continue
            if r.status_code == 202:
                pj = r.json()
                p = pj.get("progress", 0)
                if p != last_progress:
                    last_progress = p
                    if progress_log:
                        progress_log(f"video {rid[:8]}: {pj.get('status', 'pending')} {p}%")
                time.sleep(poll_interval)
                continue
            if r.status_code == 401:
                # OAuth only: re-resolve (may refresh). Flag/env: terminal.
                if source != "oauth":
                    raise XaiError(_key_rejected_msg(r.status_code, r.text),
                                   status=r.status_code, body=r.text,
                                   op="generate_video")
                token, source = resolve_token(self.auth_path, self.issuer,
                                              self.api_key, refresh=True)
                continue
            if source in ("flag", "env"):
                raise XaiError(_key_rejected_msg(r.status_code, r.text),
                               status=r.status_code, body=r.text,
                               op="generate_video")
            raise XaiError(f"video poll failed", status=r.status_code,
                           body=r.text, op="generate_video")
        if done_body is None:
            raise XaiError(f"video poll timed out after {poll_timeout}s (rid={rid})",
                           status=0, op="generate_video")
        video_field = done_body.get("video") or {}
        cdn_url = video_field.get("url")
        if not cdn_url:
            raise XaiError("video response missing video.url",
                           body=json.dumps(done_body)[:300], op="generate_video")
        mp4 = self._session.get(cdn_url, timeout=120)
        if mp4.status_code != 200:
            raise XaiError("CDN mp4 fetch failed", status=mp4.status_code,
                           body=mp4.text[:300], op="generate_video")
        if out.suffix == "":
            out = out.with_suffix(".mp4")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(mp4.content)
        _cache_store(self.cache_dir, ck, out.suffix, out)
        usage = done_body.get("usage") or {}
        cost_ticks = usage.get("cost_in_usd_ticks", usage.get("cost_usd_ticks"))
        rec = {"op": "generate_video", "mode": mode, "model": model, "prompt": prompt,
               "start_frame": str(start_frame) if start_frame else None,
               "references": [str(r) for r in references],
               "start_key": start_key, "ref_keys": ref_keys,
               "params": {"duration": duration, "aspect_ratio": aspect_ratio,
                          "resolution": resolution},
               "mime_type": "video/mp4", "out": str(out), "cache_key": ck,
               "cached": False, "http_status": 200,
               "cost_in_usd_ticks": cost_ticks,
               "request_id": rid, "cdn_url": cdn_url,
               "video_duration": video_field.get("duration")}
        cost.append(rec, self.ledger)
        return rec


# ============================================================
# Validated prompt templates (hard-scaffolded for GBA tile constraints)
# ============================================================

KEY_COLOR_HEX = "#FF00FF"  # the literal we ASK for; model renders as hot-pink ~(252,47,186)


def sprite_prompt(subject: str, *,
                  direction: str = "facing forward",
                  features: str = "",
                  palette: str = "",
                  silhouette_hint: str = "",
                  target_tile: str = "32x32",
                  colors_per_part: str = "") -> str:
    """Hard-scaffolded sprite prompt with explicit GBA-tile design constraints.

    Every section of the prompt is structured so the model can't paraphrase
    around the constraint. The schema below treats the model as a literal
    pixel-pusher, not an artist with creative latitude.

    Args:
      subject:           short name/type of the character (e.g. "red_soldier").
      direction:         orientation (e.g. "facing right", "3/4 view front").
      features:          enumerated visible features, comma-separated. Be EXACT.
                         "two short horns, large round head, no visible face,
                          square chest plate with delta-triangle, thin sword in
                          right hand, blocky boots, no cape, no tail".
      palette:           the EXACT colors allowed on the subject. Enumerate.
                         "steel-blue armor (#5a78a8), dark navy outline (#1a2540),
                          cyan glow on chest (#00e0e0), white delta symbol (#ffffff),
                          pale-gray sword (#c0c8d0)". 4-6 colors total max.
      silhouette_hint:   the iconic shape the model must produce at tile scale.
                         "horned helmet silhouette dominates the top half;
                          chunky armored torso; stubby legs; sword extends
                          beyond outline on the right".
      target_tile:       the GBA tile size this is DESIGNED for: "16x16",
                         "32x32", or "32x64". Drives chunkiness/detail level.
      colors_per_part:   legacy parameter, mapped to `palette` if both given.

    A caller that provides only `subject` gets a generic prompt. A caller that
    fills `features` + `palette` + `silhouette_hint` gets a locked composition.
    """
    # legacy compat: callers passing only colors_per_part get it appended to palette
    if colors_per_part and not palette:
        palette = colors_per_part
    target = target_tile.lower()
    chunkiness_clause = {
        "16x16": ("This sprite is DESIGNED FOR A 16x16 GBA TILE. Render it as a "
                  "chunky pictographic icon -- exaggerated proportions, 1-2 "
                  "iconic features only, NO facial features (too small to "
                  "resolve), limbs are 2-pixel-wide blocks, head is roughly "
                  "1/3 of body height. The figure must read at a glance when "
                  "scaled to a 16x16 tile."),
        "32x32": ("This sprite is DESIGNED FOR A 32x32 GBA TILE. Render it as "
                  "a stocky pixel-art figure with bold simple shapes, eyes are "
                  "1-2 pixel dots, hands and feet are 2-3 pixel blocks, head "
                  "is roughly 1/3 of body height. Every feature must be "
                  "readable when scaled to a 32x32 tile."),
        "32x64": ("This sprite is DESIGNED FOR A 32x64 GBA TILE (battle-preview "
                  "scale). Render it as a stocky pixel-art figure, full body "
                  "filling the tall tile, head roughly 1/4 of body height, "
                  "clear silhouette readable when scaled to 32x64."),
    }.get(target, (f"This sprite is DESIGNED FOR A {target} GBA tile. Bold "
                   f"silhouette, chunky proportions, readable at that scale."))

    sections: list[str] = []
    sections.append(
        f"A single full-body PIXEL ART SPRITE of a {subject}, "
        f"{direction}, centered, filling about 80% of the frame vertically.")
    sections.append(chunkiness_clause)
    if features:
        sections.append(
            f"VISIBLE FEATURES (render exactly these and no others): {features}.")
    if silhouette_hint:
        sections.append(f"SILHOUETTE: {silhouette_hint}.")
    if palette:
        sections.append(
            f"PALETTE (the ONLY colors allowed on the subject -- 4 to 6 colors "
            f"total max, NO gradients between them, every pixel is one of "
            f"these flat values): {palette}.")
    sections.append(
        "RENDERING: NES/SNES/GBA-era pixel art style. Hard 1-pixel-wide black "
        "or near-black outline around every edge of the subject (including "
        "internal silhouette boundaries between body parts). Flat colors ONLY. "
        "NO anti-aliasing. NO smooth shading. NO gradients. NO highlights. NO "
        "shadows on the subject. Every pixel is a discrete blocky tile.")
    sections.append(
        f"BACKGROUND: solid uniform magenta {KEY_COLOR_HEX} filling the entire "
        "frame EXCEPT where the subject is. The magenta is completely flat -- "
        "no shading, no gradient, no vignette, no darker edges, no border, "
        "no texture. Just one flat magenta value across every background pixel.")
    sections.append(
        f"DO NOT (anti-patterns): do NOT use any pink, magenta, or hot-pink "
        f"color ANYWHERE on the {subject} itself. Do NOT add a ground plane, "
        "floor line, shadow under feet, or horizon line. Do NOT add any "
        "additional characters, props, items, weapons, or accessories beyond "
        "what is listed in VISIBLE FEATURES. Do NOT add text, signatures, "
        "logos, watermarks, or borders. Do NOT use realistic rendering, "
        "smooth lighting, 3D shading, or any non-pixel-art style.")
    return "\n\n".join(sections)


def texture_prompt(material: str, *,
                   target_tile: str | None = None,
                   scale_hint: str | None = None,
                   source_resolution: int = 1024) -> str:
    """Uniformity prompt for terrain that wraps via make_tileable.

    Args:
      material:           short name of the material (e.g. "rippling green
                          grass", "data-cell circuit pattern in cyan on dark
                          blue").
      target_tile:        OPTIONAL "WxH" target tile size (e.g. "16x16"). When
                          set (and `scale_hint` is unset), auto-computes the
                          feature-scale clause as "features each X-Y source
                          pixels (= 1-2 target tile pixels)" using the
                          source-to-target ratio. This is the fix for the
                          2026-05-21 finding that "small uniform features"
                          produces featureless 16x16 bakes because the model
                          sizes features in SOURCE pixels, not target pixels.
      scale_hint:         OPTIONAL explicit override (e.g. "tight 1-pixel-wide
                          flow lines"). Wins over `target_tile` when set. Use
                          for terrain types where the auto-computed hint is
                          wrong (e.g. "long horizontal flow lines" for a
                          Bus/data-channel terrain where 1-2-pixel blob
                          features wouldn't read as directional flow).
      source_resolution:  the model's source-canvas size (default 1024 for
                          `--resolution 1k`; pass 2048 for `--resolution 2k`).

    Auto-derived scale-hint (1024 source):
      target_tile="8x8"   -> features each 128-256 source pixels (= 1-2 target px)
      target_tile="16x16" -> features each 64-128 source pixels (= 1-2 target px)
      target_tile="32x32" -> features each 32-64 source pixels (= 1-2 target px)
      target_tile="64x64" -> features each 16-32 source pixels (= 1-2 target px)

    Validated 2026-05-21: 16x16 Heap terrain shipped on-spec with the
    auto-derived "features each 64-128 source pixels" clause (v3 ad-hoc
    landed at this scale; codified here as the default).
    """
    if scale_hint is None and target_tile is not None:
        try:
            normalized = target_tile.lower().replace("*", "x").replace(",", "x")
            tw, th = (int(p) for p in normalized.split("x"))
        except (ValueError, TypeError):
            raise ValueError(
                f"texture_prompt: bad target_tile {target_tile!r}; expected 'WxH'")
        target_dim = max(tw, th)
        ratio = max(1, source_resolution // target_dim)
        # 1-2 target tile pixels worth of source pixels each feature.
        scale_hint = (
            f"chunky blocky features sized at {ratio}-{ratio * 2} source "
            f"pixels each (= 1-2 target tile pixels at the {tw}x{th} target "
            f"tile size), NOT thin lines or fine detail")
    elif scale_hint is None:
        scale_hint = "small uniform features"
    parts = [
        f"a SEAMLESS REPEATING tileable texture of {material}",
        "completely flat and even",
        "NO focal point, NO center, NO large features",
        f"{scale_hint}, distributed evenly across the ENTIRE frame edge to edge",
        "like a stock texture swatch",
        "fills the whole frame uniformly with no darker edges",
        "no text, no border, no vignette",
    ]
    return ". ".join(parts) + "."


def ui_icon_prompt(subject: str, *,
                   features: str = "",
                   palette: str = "",
                   target_tile: str = "16x16",
                   key_color: str = KEY_COLOR_HEX) -> str:
    """Hard-scaffolded UI-icon prompt for HUD elements (cursor, mini-icon, button face).

    Distinct from sprite_prompt: an icon is a SHAPE, not a character. No
    anatomy, no posture, no implied figure. Composition is axis-aligned,
    symmetric where the icon convention demands it (e.g. button face), and
    the figure fills 70-90% of the frame with the chosen iconic motif.

    Validated 2026-05-21 via the working cursor probe (sprite template
    repurposed). This codifies the working pattern into a dedicated kind so
    UI work no longer pays the character-anatomy clauses sprite_prompt
    enforces.

    Args:
      subject:        short name of the UI element (e.g. "selection cursor",
                      "menu arrow", "stat-bar end-cap icon").
      features:       enumerated visible features (e.g. "diagonal arrow
                      pointing to upper-left, thick body, single bright
                      outline, no shaft tail").
      palette:        3-4 hex-coded colors total. Icons typically use fewer
                      colors than units (high contrast for readability at
                      tile scale).
      target_tile:    target tile size; drives the chunkiness clause.
      key_color:      bg key literal (default magenta; override per per-
                      faction-key-color doctrine when the icon's accent
                      would conflict).
    """
    target = target_tile.lower()
    chunkiness_clause = {
        "8x8": ("This icon is DESIGNED FOR AN 8x8 GBA TILE. Reduce to ONE "
                "iconic shape only -- a single arrow, dot, slash, or block. "
                "No internal detail. The icon must be readable as one mark "
                "when scaled to 8x8."),
        "16x16": ("This icon is DESIGNED FOR A 16x16 GBA TILE. Render it as "
                  "a chunky pictographic icon -- 1-2 iconic features only, "
                  "2-pixel-wide strokes minimum, no fine internal detail. "
                  "The icon must read at a glance when scaled to 16x16."),
        "32x32": ("This icon is DESIGNED FOR A 32x32 GBA TILE. Render as a "
                  "bold pictographic icon with 2-3 readable features at the "
                  "target scale; 2-3 pixel strokes minimum."),
    }.get(target, (f"This icon is DESIGNED FOR A {target} GBA tile. Bold "
                   f"shape, axis-aligned, readable at that scale."))
    sections: list[str] = []
    sections.append(
        f"A single PIXEL ART UI ICON of a {subject}, centered in the frame, "
        f"filling 70-90% of the frame, shape only -- NOT a character, NOT a "
        f"figure. The shape's orientation (axis-aligned, diagonal, rotated) "
        f"matches what the FEATURES clause describes; cursors and chevrons are "
        f"diagonal, menu arrows and buttons are axis-aligned.")
    sections.append(chunkiness_clause)
    if features:
        sections.append(
            f"VISIBLE FEATURES (render exactly these and no others): {features}.")
    if palette:
        sections.append(
            f"PALETTE (the ONLY colors allowed on the icon -- 3 to 4 colors "
            f"total max, NO gradients, every pixel is one of these flat "
            f"values): {palette}.")
    sections.append(
        "RENDERING: NES/SNES/GBA-era UI icon style. Hard 1-pixel-wide black or "
        "near-black outline around every edge of the icon shape. Flat fills "
        "inside. NO anti-aliasing, NO smooth shading, NO gradients, NO "
        "highlights, NO shadows. Discrete blocky pixels.")
    sections.append(
        f"BACKGROUND: solid uniform {key_color} filling the entire frame "
        f"EXCEPT where the icon is. Completely flat -- no shading, no "
        f"gradient, no vignette, no darker edges, no border, no texture.")
    sections.append(
        f"DO NOT: do NOT add any character anatomy (head, eyes, limbs, "
        f"figure outline -- this is an ABSTRACT ICON, not a tiny character). "
        f"Do NOT use the key color {key_color} on the icon itself. Do NOT add "
        f"text, signatures, watermarks, borders, or perspective.")
    return "\n\n".join(sections)


def ui_nine_slice_prompt(subject: str, *,
                         palette: str = "",
                         cell_target_tile: str = "8x8",
                         key_color: str = KEY_COLOR_HEX) -> str:
    """Hard-scaffolded prompt for a 3x3 nine-slice source image.

    Generates the SOURCE that `sprite ui-bake` consumes. The source is laid out
    as a clearly-separated 3x3 grid of 9 distinct cells, where each cell becomes
    one tile in the baked panel-chrome bank.

    Cell layout (row-major):
        [0 TL ] [1 T  ] [2 TR ]
        [3 L  ] [4 C  ] [5 R  ]
        [6 BL ] [7 B  ] [8 BR ]

    Distinct from `sprite_prompt`: the model is briefed for a STRUCTURED grid
    of 9 chrome pieces, not a single figure. The chunkiness clause keys off the
    per-cell target size (typically 8x8 for standard GBA UI; 16x16 for thicker
    chrome) so each cell renders with detail appropriate to its baked footprint.

    Args:
      subject:          panel name (e.g. "dialog frame", "menu border",
                        "stat-bar chrome").
      palette:          3-5 hex-coded colors for the chrome (outline, face, accent).
      cell_target_tile: target size of EACH baked cell (default 8x8 -- the GBA
                        nine-slice standard; 16x16 for thicker chrome).
      key_color:        bg key literal that fills the gutters between cells AND
                        any transparent regions inside cells (default magenta).
    """
    target = cell_target_tile.lower()
    cell_clause = {
        "8x8": ("Each cell is DESIGNED to bake down to an 8x8 GBA tile. "
                "Every chrome feature inside a cell must be a chunky 2-3-source-"
                "pixel-wide stroke that survives the source-to-8x8 downscale; "
                "thin 1-source-pixel lines vanish."),
        "16x16": ("Each cell is DESIGNED to bake down to a 16x16 GBA tile. "
                  "Chrome features inside a cell may carry slightly finer "
                  "detail (2-pixel-wide strokes at target scale = wider in "
                  "source); enough room for an inner-border ring around the "
                  "center cell."),
    }.get(target, (f"Each cell is DESIGNED to bake down to a {target} GBA "
                   f"tile. Chrome features in each cell must survive the "
                   f"source-to-target downscale."))
    sections: list[str] = []
    sections.append(
        f"A PIXEL ART nine-slice panel-chrome SOURCE image for a {subject}. "
        f"The image shows EXACTLY a 3x3 GRID of 9 distinct chrome cells, "
        f"clearly separated by visible gutters, intended to be sliced by a "
        f"3x3 baker and reassembled into arbitrary-size panel chrome.")
    sections.append(
        "GRID LAYOUT (3 rows, 3 columns, ALL CELLS EQUAL SIZE):\n"
        "  Row 1: [TL outer-corner: hard right-angle elbow opening down-right] "
        "[T top-edge: straight horizontal rail] "
        "[TR outer-corner: hard right-angle elbow opening down-left]\n"
        "  Row 2: [L left-edge: straight vertical rail] "
        "[C center: hollow interior fill / inner border] "
        "[R right-edge: straight vertical rail]\n"
        "  Row 3: [BL outer-corner: hard right-angle elbow opening up-right] "
        "[B bottom-edge: straight horizontal rail] "
        "[BR outer-corner: hard right-angle elbow opening up-left]\n"
        "The 4 corners are MIRROR-SYMMETRIC. The 4 edges are TRANSLATION-"
        "SYMMETRIC along their axis. The center is rotationally-symmetric.")
    sections.append(cell_clause)
    if palette:
        sections.append(
            f"PALETTE (the ONLY colors allowed on the chrome -- 3 to 5 colors "
            f"total max, NO gradients, every pixel is one of these flat values): "
            f"{palette}.")
    sections.append(
        "RENDERING: NES/SNES/GBA-era UI chrome style. Hard 1-pixel outline "
        "(in source pixels = 2-3 pixels wide at target cell scale) around "
        "every chrome edge. Flat fills inside. NO anti-aliasing, NO smooth "
        "shading, NO gradients, NO highlights, NO 3D bevels.")
    sections.append(
        f"BACKGROUND AND GUTTERS: the GUTTERS between cells AND the hollow "
        f"interior of the center cell are filled with solid uniform "
        f"{key_color} (the bg key). This is what the baker treats as "
        f"transparent. The whole image's outer margin (everything outside "
        f"the 3x3 grid) is also {key_color}. Completely flat -- no shading.")
    sections.append(
        f"DO NOT: do NOT merge adjacent cells -- the 3x3 grid must be "
        f"unambiguous with visible gutters between each pair of neighbors. "
        f"Do NOT add a 10th cell, a frame around the grid, text, labels, "
        f"signatures, or watermarks. Do NOT use {key_color} on the chrome "
        f"itself. Do NOT render any character anatomy or figures -- this is "
        f"ABSTRACT panel chrome, not a scene with elements inside it.")
    return "\n\n".join(sections)


def portrait_prompt(subject: str, *,
                    features: str = "",
                    palette: str = "",
                    expression: str = "neutral",
                    target_tile: str = "64x64",
                    key_color: str = KEY_COLOR_HEX) -> str:
    """Hard-scaffolded portrait prompt for cutscene/dialog frames.

    Portraits are head-and-shoulders compositions at larger scale than map
    sprites; eyes/nose/mouth can survive at 64x64+ where they cannot at 16x16.
    Ships via BG layer (not OBJ), so the bake doesn't OBJ-tile-pack -- use
    `sprite bake --linear` for portrait output.

    Expression axis: portrait sets typically ship N variants per character
    (neutral / talking / angry / concerned). Use the same subject + features +
    palette across the set; vary only `expression`.

    Args:
      subject:        character name (e.g. "red_soldier", "blue_faction
                      captain").
      features:       enumerated visible features (e.g. "horned helmet,
                      glowing cyan visor, armored shoulder pauldrons,
                      chest plate with delta-triangle emblem").
      palette:        4-6 hex-coded colors total; portraits tolerate richer
                      palettes than map sprites (more colors available at the
                      larger target tile size).
      expression:     expression axis ("neutral" | "talking" | "angry" |
                      "concerned" | <free-form>). The composition stays
                      identical; only expression varies.
      target_tile:    target tile size (default 64x64; 96x96 and 128x128 also
                      common for cutscene portraits).
      key_color:      bg key literal (default magenta).
    """
    target = target_tile.lower()
    composition_clause = {
        "64x64": ("This portrait is DESIGNED FOR A 64x64 GBA tile. Head-and-"
                  "shoulders composition: head fills the top 60% of the frame, "
                  "shoulders/upper chest visible in the bottom 40%, facing "
                  "the viewer (3/4 angle preferred). Eyes are 2-3-pixel "
                  "dots, nose is a 1-2 pixel mark, mouth is 2-3 pixels wide."),
        "96x96": ("This portrait is DESIGNED FOR A 96x96 cutscene portrait. "
                  "Head fills the top 50-60% of the frame, shoulders/upper "
                  "torso in the bottom 40-50%. Facial features are readable "
                  "(2-4-pixel eyes, distinct nose, mouth shape)."),
        "128x128": ("This portrait is DESIGNED FOR A 128x128 cutscene "
                    "portrait. Larger scale tolerates more detail; head fills "
                    "the top half, shoulders/upper torso in the bottom half. "
                    "Eyes can carry expression detail, nose and mouth read "
                    "as distinct features."),
    }.get(target, (f"This portrait is DESIGNED FOR A {target} portrait tile. "
                   f"Head-and-shoulders composition; head fills the top "
                   f"60%, shoulders below."))
    sections: list[str] = []
    sections.append(
        f"A PIXEL ART PORTRAIT of {subject}, head-and-shoulders composition, "
        f"facing 3/4 view toward the viewer, expression: {expression}.")
    sections.append(composition_clause)
    if features:
        sections.append(
            f"VISIBLE FEATURES (render exactly these and no others): {features}.")
    if palette:
        sections.append(
            f"PALETTE (the ONLY colors allowed on the subject -- 4 to 6 colors "
            f"total max, NO gradients, every pixel is one of these flat "
            f"values): {palette}.")
    sections.append(
        "RENDERING: NES/SNES/GBA-era cutscene portrait style. Hard 1-pixel-"
        "wide black or near-black outline around every edge of the subject "
        "and around major internal silhouette boundaries (helmet edge, "
        "shoulder edge, neck join). Flat fills inside. NO anti-aliasing, NO "
        "smooth shading (1-2 fixed shade levels per color region are "
        "acceptable; gradients are NOT), NO highlights beyond pinned bright "
        "accent pixels, NO realistic rendering.")
    sections.append(
        f"BACKGROUND: solid uniform {key_color} filling every non-subject "
        f"pixel. Completely flat -- NO shading, gradient, vignette, darker "
        f"edges, ground plane, horizon, shadow, or framing border.")
    sections.append(
        f"DO NOT: do NOT use the key color {key_color} on the subject. Do "
        f"NOT add a body below the chest (this is a head-and-shoulders "
        f"portrait, not a full figure). Do NOT add text, name plate, "
        f"signature, watermark, or border. Do NOT add additional characters "
        f"or props beyond what is listed in VISIBLE FEATURES.")
    return "\n\n".join(sections)

def walk_video_prompt(subject: str, *,
                      colors_per_part: str = "",
                      view: str = "side view",
                      reference_description: str = "",
                      with_reference: bool = False,
                      facing: str = "right",
                      palette: str = "",
                      forbid_anatomy: str = ("human face, exposed skin, flesh tones, "
                                             "eyes, eyebrows, nose, mouth, lips, ears, hair, "
                                             "fingers (use blocky mitt hands instead)")) -> str:
    """Hard-scaffolded walk-video prompt with frame-by-frame motion mechanics.

    The model's training-data bias is strong for "human warrior in armor" --
    even with a non-human reference image, it will silently introduce a face,
    skin tones, hair, or fingers inside an otherwise faceless helmet. The
    `forbid_anatomy` clause negates that bias explicitly. Override only if the
    target IS a humanoid (e.g. operator soldier sprites). For non-humanoid
    units (daemon imps, mechanical modules, abstract entities), keep the
    default to enforce the reference's anatomy.

    `palette` (recommended) enumerates the allowed colors as hex codes. The
    model lifts color from the reference image when it can, but the text
    branch can introduce off-palette colors (especially flesh tones); the
    palette lock pushes back. Same shape as `sprite_prompt`'s `palette` arg.

    For ref-anchored video (the canonical workflow), pass `with_reference=True`
    plus a `reference_description` that names the visible features. The model's
    text branch dominates the reference; the reference alone won't lock identity.
    """
    sections: list[str] = []

    # 1. Character identity
    if with_reference:
        anchor_desc = reference_description or subject
        sections.append(
            f"This video shows the character from the reference image -- "
            f"{anchor_desc} -- performing a COMPLETE WALK CYCLE with DRAMATIC, "
            f"VISIBLE leg and arm motion every single frame.\n\n"
            f"APPEARANCE LOCK (what stays IDENTICAL to the reference across "
            f"every frame): the character's species/anatomy, colors and "
            f"palette, outline, silhouette proportions, helmet, chest emblem, "
            f"weapon design, equipment. These DO NOT change.\n\n"
            f"POSE VARIES (what CHANGES every frame): leg position, arm "
            f"position, foot lift, sword angle, body lean. The character is "
            f"WALKING -- limbs must visibly cycle through stride positions. "
            f"A static front-facing stance with arms out is WRONG. Every "
            f"frame should look mid-stride at a different point in the walk "
            f"cycle described below.")
    else:
        sections.append(
            f"This video shows a pixel-art {subject} performing a COMPLETE "
            f"walk cycle with DRAMATIC, VISIBLE leg and arm motion every frame. "
            f"The character is WALKING, not posing -- limbs must cycle "
            f"through stride positions, not stay in a battle stance.")
        if colors_per_part:
            sections.append(
                f"Character colors (EXACTLY these, nothing else): {colors_per_part}.")

    sections.append(
        f"CAMERA: static, {view}, fixed. NO pan, zoom, rotation, dolly. "
        f"Character stays centered horizontally and vertically -- walks IN "
        f"PLACE (legs cycle, body does not translate across frame).")

    sections.append(
        f"WALK MECHANICS (4-pose loop, {view}, facing {facing}):\n"
        f"  A (contact): {facing} foot forward planted, other foot lifted "
        f"  behind. Opposite arm FORWARD, {facing} arm BACK.\n"
        f"  B (passing): legs near together under hips, arms passing body.\n"
        f"  C (contact): MIRRORED -- other foot forward, {facing} arm now FORWARD.\n"
        f"  D (passing): mirrors B.\n"
        f"All four limbs alternate every cycle. Head bobs 1-2px (down at "
        f"contact A/C, up at passing B/D). Weapons stay gripped and swing "
        f"WITH the holding arm. Cape/tail trails 1-2 frames behind motion.")

    sections.append(
        f"RENDERING: discrete pixel-art frames matching the reference style "
        f"EXACTLY -- hard 1px outline, flat colors, no anti-aliasing, no "
        f"gradients, no shading, no motion blur, no inter-frame tweening. "
        f"Looks like 4-8 hand-painted frames in sequence, NOT 3D animation.")

    sections.append(
        f"BACKGROUND: solid uniform magenta {KEY_COLOR_HEX} filling every "
        f"non-character pixel. Completely flat -- NO shading, gradient, "
        f"vignette, darker edges, ground plane, horizon, shadow, floor line.")

    if palette:
        sections.append(
            f"PALETTE LOCK: character uses ONLY: {palette}. NO other colors. "
            f"Specifically NO flesh, skin, hair, tan, peach, beige, or warm "
            f"human tones unless explicitly listed.")

    if forbid_anatomy:
        sections.append(
            f"ANATOMY LOCK: anatomy matches the reference EXACTLY. The "
            f"following do NOT appear on the reference and must NOT appear "
            f"in the video: {forbid_anatomy}. If the reference helmet shows "
            f"NO face, the video helmet shows no face (no eyes/nose/mouth "
            f"revealed). If the reference has blocky mitt-hands, keep mitt-"
            f"hands (no fingers). The character is NOT a human in armor -- "
            f"it is the EXACT entity the reference shows.")

    sections.append(
        f"DO NOT: animate only one limb (ALL FOUR alternate every cycle); "
        f"use pink/magenta/hot-pink on the character; add or remove features "
        f"vs the reference; translate the character across the frame; add "
        f"motion blur, 3D tweening, or non-pixel-art rendering; add ground "
        f"plane, shadow, text, watermark, or border; 'humanize' the character "
        f"with face/skin/hair/fingers absent from the reference -- species "
        f"and anatomy come from the reference, not a human-warrior template.")

    out = "\n\n".join(sections)
    if len(out) > 4096:
        raise ValueError(
            f"walk_video_prompt produced a {len(out)}-char prompt; xAI video "
            f"endpoint hard-caps at 4096. Trim `reference_description` "
            f"(currently {len(reference_description)} chars), `palette` "
            f"({len(palette)} chars), or `forbid_anatomy` "
            f"({len(forbid_anatomy)} chars) -- the scaffolding overhead "
            f"itself runs ~1800 chars before user content.")
    return out
