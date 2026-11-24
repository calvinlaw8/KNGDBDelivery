"""Command-line interface for the shared configuration core."""

import argparse
import json
import sys
from pathlib import Path

from .generations import GenerationError, new_utc_generation_id, publish_staging, resolve_current
from .legacy_input import LegacyInputError, config_from_nul_bytes
from .migrate import MigrationError, archive_legacy_bytes, archive_legacy_env, inspect_legacy_env
from .render import RenderError, render_files, write_staging_directory
from .schema import ConfigSchemaError, load_config
from .validate import format_text, validation_result


MINIMUM_PYTHON = (3, 9)


def doctor_result():
    checks = {
        "python_version": sys.version_info[:2] >= MINIMUM_PYTHON,
        "utf8_encoding": (sys.stdin.encoding or "").lower().replace("-", "") == "utf8",
        "standard_library": all(
            module is not None
            for module in (
                __import__("argparse"),
                __import__("hmac"),
                __import__("json"),
                __import__("secrets"),
                __import__("tempfile"),
            )
        ),
    }
    return {
        "valid": all(checks.values()),
        "minimum_python": ".".join(str(part) for part in MINIMUM_PYTHON),
        "python_version": ".".join(str(part) for part in sys.version_info[:3]),
        "checks": checks,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m configurator")
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate", help="validate a versioned JSON configuration")
    validate_parser.add_argument("config", nargs="?", default="-", help="JSON file path, or - for stdin")
    validate_parser.add_argument("--format", choices=("json", "text"), default="text")
    render_parser = subparsers.add_parser("render", help="render validated configuration into a new staging directory")
    render_parser.add_argument("config", type=Path)
    render_parser.add_argument("--output", type=Path, required=True)
    render_parser.add_argument("--project-root", type=Path, required=True)
    render_parser.add_argument("--runtime-playbook-dir", type=Path)
    render_parser.add_argument("--templates", type=Path, default=Path(__file__).resolve().parent.parent / "playbooks/group_vars")
    wizard_parser = subparsers.add_parser("render-wizard", help="render NUL-delimited wizard input into a new staging directory")
    wizard_parser.add_argument("--output", type=Path, required=True)
    wizard_parser.add_argument("--project-root", type=Path, required=True)
    wizard_parser.add_argument("--runtime-playbook-dir", type=Path)
    wizard_parser.add_argument("--templates", type=Path, default=Path(__file__).resolve().parent.parent / "playbooks/group_vars")
    validate_wizard_parser = subparsers.add_parser("validate-wizard", help="validate NUL-delimited wizard input from stdin")
    validate_wizard_parser.add_argument("--format", choices=("json", "text"), default="text")
    subparsers.add_parser("new-generation-id", help="create an unpredictable runtime generation id")
    publish_parser = subparsers.add_parser("publish-generation", help="atomically publish a complete staging directory")
    publish_parser.add_argument("--runtime-dir", type=Path, required=True)
    publish_parser.add_argument("--staging", type=Path, required=True)
    publish_parser.add_argument("--generation-id", required=True)
    current_parser = subparsers.add_parser("current-generation", help="resolve the current generation directory")
    current_parser.add_argument("--runtime-dir", type=Path, required=True)
    inspect_parser = subparsers.add_parser("inspect-legacy", help="safely inspect a legacy config.env without executing it")
    inspect_parser.add_argument("config", type=Path)
    archive_parser = subparsers.add_parser("archive-legacy", help="atomically archive a recognized legacy config.env")
    archive_parser.add_argument("config", type=Path)
    archive_parser.add_argument("--runtime-dir", type=Path, required=True)
    archive_raw_parser = subparsers.add_parser("archive-legacy-raw", help="atomically archive a legacy file without interpreting it")
    archive_raw_parser.add_argument("config", type=Path)
    archive_raw_parser.add_argument("--runtime-dir", type=Path, required=True)
    reconcile_parser = subparsers.add_parser("reconcile-resources", help="merge non-sensitive remote facts with a managed-resource declaration")
    reconcile_parser.add_argument("manifest", type=Path)
    reconcile_parser.add_argument("--facts", type=Path, required=True)
    cleanup_parser = subparsers.add_parser("cleanup-plan", help="build a non-executing cleanup plan")
    cleanup_parser.add_argument("manifest", type=Path)
    cleanup_parser.add_argument("--reconciliation", type=Path, required=True)
    cleanup_parser.add_argument("--components", required=True, help="comma-separated component names")
    rebuild_parser = subparsers.add_parser("rebuild-plan", help="build a non-executing one-component rebuild plan")
    rebuild_parser.add_argument("manifest", type=Path)
    rebuild_parser.add_argument("--reconciliation", type=Path, required=True)
    rebuild_parser.add_argument("--backup-declaration", type=Path, required=True)
    rebuild_parser.add_argument("--component", required=True)
    doctor_parser = subparsers.add_parser("doctor", help="check local Python and standard-library prerequisites")
    doctor_parser.add_argument("--format", choices=("json", "text"), default="text")
    subparsers.add_parser("workbench", help="start the loopback-only offline configuration workbench")
    arguments = parser.parse_args(argv)

    if arguments.command == "workbench":
        from .workbench import serve

        return serve()

    if arguments.command == "doctor":
        result = doctor_result()
        if arguments.format == "json":
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        else:
            print("Python {0} (requires {1}+): {2}".format(result["python_version"], result["minimum_python"], "ok" if result["checks"]["python_version"] else "failed"))
            print("UTF-8 stdin: {0}".format("ok" if result["checks"]["utf8_encoding"] else "failed"))
            print("standard library: {0}".format("ok" if result["checks"]["standard_library"] else "failed"))
        return 0 if result["valid"] else 2

    if arguments.command == "new-generation-id":
        print(new_utc_generation_id())
        return 0

    if arguments.command == "publish-generation":
        try:
            destination = publish_staging(arguments.runtime_dir, arguments.staging, arguments.generation_id)
        except (GenerationError, FileExistsError, OSError) as error:
            print("publish failed: {0}".format(error), file=sys.stderr)
            return 2
        print(str(destination))
        return 0

    if arguments.command == "current-generation":
        try:
            current = resolve_current(arguments.runtime_dir)
        except (GenerationError, OSError) as error:
            print("resolve failed: {0}".format(error), file=sys.stderr)
            return 2
        if current is None:
            return 1
        print(str(current))
        return 0

    if arguments.command == "inspect-legacy":
        try:
            preview = inspect_legacy_env(arguments.config)
        except (MigrationError, OSError) as error:
            print("legacy inspection failed: {0}".format(error), file=sys.stderr)
            return 2
        print(json.dumps(preview, ensure_ascii=False, sort_keys=True))
        return 0

    if arguments.command == "archive-legacy":
        try:
            backup = archive_legacy_env(arguments.config, arguments.runtime_dir)
        except (MigrationError, OSError) as error:
            print("legacy archive failed: {0}".format(error), file=sys.stderr)
            return 2
        print(str(backup))
        return 0

    if arguments.command == "archive-legacy-raw":
        try:
            backup = archive_legacy_bytes(arguments.config, arguments.runtime_dir)
        except (MigrationError, OSError) as error:
            print("legacy raw archive failed: {0}".format(error), file=sys.stderr)
            return 2
        print(str(backup))
        return 0

    if arguments.command == "reconcile-resources":
        try:
            from .ownership import reconcile_manifest

            manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
            facts_document = json.loads(arguments.facts.read_text(encoding="utf-8"))
            facts = facts_document if isinstance(facts_document, dict) else {}
            report = reconcile_manifest(manifest, facts)
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
            print("resource reconciliation failed: {0}".format(error), file=sys.stderr)
            return 2
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
        return 2 if report["blocked"] else 0

    if arguments.command == "cleanup-plan":
        try:
            from .cleanup import build_cleanup_plan

            manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
            reconciliation = json.loads(arguments.reconciliation.read_text(encoding="utf-8"))
            components = [item.strip() for item in arguments.components.split(",") if item.strip()]
            plan = build_cleanup_plan(manifest, reconciliation, components)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            print("cleanup plan failed: {0}".format(error), file=sys.stderr)
            return 2
        print(json.dumps(plan, ensure_ascii=False, sort_keys=True))
        return 0

    if arguments.command == "rebuild-plan":
        try:
            from .rebuild import build_rebuild_plan

            manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
            reconciliation = json.loads(arguments.reconciliation.read_text(encoding="utf-8"))
            backup = json.loads(arguments.backup_declaration.read_text(encoding="utf-8"))
            plan = build_rebuild_plan(manifest, reconciliation, arguments.component, backup)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
            print("rebuild plan failed: {0}".format(error), file=sys.stderr)
            return 2
        print(json.dumps(plan, ensure_ascii=False, sort_keys=True))
        return 0

    if arguments.command in ("render", "render-wizard"):
        try:
            config = load_config(arguments.config) if arguments.command == "render" else config_from_nul_bytes(sys.stdin.buffer.read())
            runtime_playbook_dir = arguments.runtime_playbook_dir or arguments.output / "playbooks"
            files = render_files(config, arguments.project_root, runtime_playbook_dir, arguments.templates)
            write_staging_directory(arguments.output, files)
        except (ConfigSchemaError, LegacyInputError, RenderError, FileExistsError, OSError) as error:
            print("render failed: {0}".format(error), file=sys.stderr)
            return 2
        print(json.dumps({"output": str(arguments.output), "files": sorted(files)}, ensure_ascii=False))
        return 0

    if arguments.command == "validate-wizard":
        try:
            config = config_from_nul_bytes(sys.stdin.buffer.read())
        except LegacyInputError as error:
            result = {"valid": False, "issues": [{"code": "wizard_input_invalid", "path": "", "message": str(error), "severity": "error"}]}
        else:
            result = validation_result(config)
        if arguments.format == "json":
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        else:
            from .validate import ValidationIssue

            print(format_text([ValidationIssue(**issue) for issue in result["issues"]]))
        return 0 if result["valid"] else 2

    source = sys.stdin.read() if arguments.config == "-" else Path(arguments.config)
    try:
        config = load_config(source)
    except ConfigSchemaError as error:
        result = {"valid": False, "issues": [{**error.as_dict(), "severity": "error"}]}
    else:
        result = validation_result(config)

    if arguments.format == "json":
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    else:
        from .validate import ValidationIssue

        print(format_text([ValidationIssue(**issue) for issue in result["issues"]]))
    return 0 if result["valid"] else 2


if __name__ == "__main__":
    sys.exit(main())