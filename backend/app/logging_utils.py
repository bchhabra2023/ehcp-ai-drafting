import json
import traceback
from datetime import datetime, timezone


def _truncate(value, limit: int = 600):
    text = str(value)
    if len(text) <= limit:
        return text
    return text[:limit] + "...<truncated>"


def _response_text_preview(response) -> str | None:
    if response is None:
        return None

    body = None
    text_attr = getattr(response, "text", None)
    if callable(text_attr):
        try:
            body = text_attr()
        except Exception:
            body = None
    elif text_attr is not None:
        body = text_attr

    if body is None:
        content = getattr(response, "content", None)
        if content is not None:
            body = content

    if body is None:
        return None

    return _truncate(body)


def describe_exception(exc: Exception) -> dict:
    data = {
        "error_type": type(exc).__name__,
        "error": _truncate(exc),
    }

    status_code = getattr(exc, "status_code", None)
    if status_code is not None:
        data["status_code"] = status_code

    error_obj = getattr(exc, "error", None)
    error_code = getattr(error_obj, "code", None)
    if error_code:
        data["service_error_code"] = error_code

    response = getattr(exc, "response", None)
    if response is not None:
        response_status = getattr(response, "status_code", None)
        if response_status is not None:
            data["response_status"] = response_status
        headers = getattr(response, "headers", None)
        if headers:
            for header_name in ("x-ms-request-id", "apim-request-id", "x-ms-error-code"):
                if header_name in headers:
                    data[header_name.replace("-", "_")] = headers.get(header_name)
        preview = _response_text_preview(response)
        if preview:
            data["response_preview"] = preview

    data["traceback"] = _truncate(traceback.format_exc(), limit=4000)
    return data


def emit_log(component: str, event_name: str, **fields):
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "component": component,
        "event": event_name,
    }
    payload.update(fields)
    print(json.dumps(payload, ensure_ascii=False, default=str), flush=True)
