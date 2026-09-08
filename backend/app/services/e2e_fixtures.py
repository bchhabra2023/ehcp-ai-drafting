import json
import os
from pathlib import Path
from typing import Iterable


_ENABLED_VALUES = {"1", "true", "yes", "on"}
_STAGES = (
    ("agent_reader", "DocumentReaderAgent"),
    ("agent_extractor", "ExtractorAgent"),
    ("agent_validator", "ValidatorAgent"),
    ("agent_quality", "QualityCheckerAgent"),
)
_DOC_KEY_TO_FILENAME = {
    "personal": "personal_details.json",
    "education": "education_advice.json",
    "health": "health_advice.json",
    "socialcare": "socialcare_advice.json",
}


def e2e_fixture_mode_enabled() -> bool:
    return os.getenv("E2E_FIXTURE_MODE", "").strip().lower() in _ENABLED_VALUES


def get_fixture_case_name() -> str:
    return os.getenv("E2E_FIXTURE_CASE", "simple").strip().lower() or "simple"


def _backend_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _fixture_case_dir() -> Path:
    case_dir = _backend_root() / "e2e_fixtures" / get_fixture_case_name()
    if not case_dir.is_dir():
        raise FileNotFoundError(f"E2E fixture case directory not found: {case_dir}")
    return case_dir


def load_fixture_json(doc_key: str) -> dict:
    fixture_path = _fixture_case_dir() / _DOC_KEY_TO_FILENAME[doc_key]
    with fixture_path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def load_fixture_child_name() -> str | None:
    personal = load_fixture_json("personal")
    return personal.get("name") or personal.get("preferred_name")


def write_fixture_outputs(file_configs: Iterable[dict]) -> list[dict]:
    results = []
    for cfg in file_configs:
        output_path = cfg["output_file"]
        validation_path = cfg["validation_output_file"]
        doc_key = cfg["doc_key"]

        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as handle:
            json.dump(load_fixture_json(doc_key), handle, indent=2, ensure_ascii=False)

        validation_payload = {
            "summary": {
                "status": "fixture-mode",
                "accuracy_percentage": 100,
                "notes": [
                    f"Generated from local '{get_fixture_case_name()}' E2E fixtures."
                ],
            }
        }
        with open(validation_path, "w", encoding="utf-8") as handle:
            json.dump(validation_payload, handle, indent=2, ensure_ascii=False)

        results.append(
            {
                "filename": os.path.basename(cfg["input_docx"]),
                "output_file": os.path.basename(output_path),
                "validation_file": os.path.basename(validation_path),
                "success": True,
            }
        )

    return results


def build_fixture_progress_events(file_configs: Iterable[dict]) -> list[dict]:
    events = []
    for cfg in file_configs:
        file_path = cfg["input_docx"]
        elapsed = 0.0
        for stage, agent in _STAGES:
            events.append(
                {
                    "file_path": file_path,
                    "stage": stage,
                    "event": "start",
                    "agent": agent,
                }
            )
            elapsed += 0.1
            events.append(
                {
                    "file_path": file_path,
                    "stage": stage,
                    "event": "done",
                    "agent": agent,
                    "elapsed_seconds": elapsed,
                }
            )
    return events
