#!/usr/bin/env python3
"""
Interactive Vast.ai DeepFaceLab provisioning CLI.

This tool wraps the Vast.ai CLI utilities to help you:
  • Search GPU offers and machine-matched volume asks
  • Create and manage DeepFaceLab-focused templates
  • Launch new instances with template + volume selections
  • Execute ad-hoc commands and monitor provisioning logs

Prerequisites:
  • Python 3.9+
  • Vast.ai CLI installed (`pip install vastai`)
  • Vast.ai API key configured (`vastai set api-key ...` or env var `VAST_API_KEY`)

Run `python config/provisioning/vastai_dfl_cli.py --print-readme` for a quick start guide.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import textwrap
from dataclasses import dataclass
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple, Union


README_SNIPPET = textwrap.dedent(
    """
    Vast.ai DeepFaceLab CLI
    =======================

    Requirements
    ------------
    • Python 3.9 or newer
    • Vast.ai CLI installed (`pip install vastai`) and available on PATH
    • Vast.ai API key configured via `vastai set api-key` or `VAST_API_KEY` env var
    • (Optional) Set `VAST_OWNER_ID` or pass `--owner-id` to filter personal templates

    Launch
    ------
    python config/provisioning/vastai_dfl_cli.py

    Highlights
    ----------
    • Offer Search: interactive filters, auto-fetch matched volume asks
    • Template Manager: list/create DeepFaceLab templates with provisioning script
    • Provision Wizard: select offer → template → volume, then create instance
    • Instance Tools: run remote commands, tail logs, detect provisioning success

    Useful Docs
    -----------
    • Vast.ai CLI commands: https://docs.vast.ai/cli/commands
    • Template advanced setup: https://docs.vast.ai/documentation/templates/advanced-setup
    • Storage types & volumes: https://docs.vast.ai/documentation/instances/storage/types
    """
).strip()


class VastAICommandError(RuntimeError):
    """Raised when a Vast.ai CLI command fails."""

    def __init__(self, command: Sequence[str], exit_code: int, stderr: str):
        super().__init__(
            f"Command {' '.join(shlex.quote(part) for part in command)} failed with exit code {exit_code}"
        )
        self.command = list(command)
        self.exit_code = exit_code
        self.stderr = stderr


@dataclass
class CLIChoice:
    key: str
    label: str
    handler: Callable[[], None]


@dataclass
class VolumePlan:
    mode: str
    identifier: Optional[Union[str, int]]
    mount_path: str = "/workspace"
    size_gb: Optional[int] = None
    label: Optional[str] = None

    @classmethod
    def none(cls) -> "VolumePlan":
        return cls(mode="none", identifier=None)

    @classmethod
    def create(cls, identifier: Union[str, int], size_gb: int, label: str, mount_path: str) -> "VolumePlan":
        return cls(mode="create", identifier=identifier, mount_path=mount_path, size_gb=size_gb, label=label)

    @classmethod
    def link(cls, identifier: Union[str, int], mount_path: str) -> "VolumePlan":
        return cls(mode="link", identifier=identifier, mount_path=mount_path)


class VastAIClient:
    """Thin wrapper around the Vast.ai CLI."""

    def __init__(self, binary: str = "vastai", api_key: Optional[str] = None):
        self.binary = binary
        self.api_key = api_key or os.environ.get("VAST_API_KEY")

    def _compose_command(self, *args: str, raw: bool = False) -> List[str]:
        command = [self.binary]
        command.extend(args)
        if raw:
            command.append("--raw")
        if self.api_key:
            command.extend(["--api-key", self.api_key])
        return command

    def run(self, *args: str, raw: bool = False, capture_json: bool = False) -> Any:
        """Execute a Vast.ai CLI command."""
        command = self._compose_command(*args, raw=raw or capture_json)
        try:
            result = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except FileNotFoundError:
            raise VastAICommandError(command, 127, "vastai CLI not found in PATH")

        if result.returncode != 0:
            raise VastAICommandError(command, result.returncode, result.stderr.strip())

        if capture_json:
            data = result.stdout.strip()
            if not data:
                return {}
            decoder = json.JSONDecoder()
            try:
                start = self._find_json_start(data)
                if start > 0:
                    data = data[start:]
                obj, _ = decoder.raw_decode(data)
                return obj
            except json.JSONDecodeError as exc:
                cleaned = self._extract_json_payload(data)
                if cleaned is not None:
                    try:
                        obj, _ = decoder.raw_decode(cleaned)
                        return obj
                    except json.JSONDecodeError:
                        pass
                return data
        return result.stdout

    def format_command(self, *args: str, raw: bool = False, capture_json: bool = False) -> str:
        command = self._compose_command(*args, raw=raw or capture_json)
        return " ".join(shlex.quote(part) for part in command)

    def stream(self, *args: str, raw: bool = False) -> Iterable[str]:
        """Stream output of a Vast.ai CLI command line-by-line."""
        command = self._compose_command(*args, raw=raw)
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        terminated = False
        try:
            for line in process.stdout:
                yield line.rstrip("\n")
        except KeyboardInterrupt:
            process.terminate()
            terminated = True
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                terminated = True
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            if process.stdout:
                process.stdout.close()
            stderr_data = ""
            if process.stderr:
                stderr_data = process.stderr.read()
                process.stderr.close()
            exit_code = process.returncode if process.returncode is not None else 0
            if terminated and exit_code in (-signal.SIGTERM, 0):
                exit_code = 0
            if exit_code not in (0, -15, signal.SIGTERM):
                raise VastAICommandError(command, exit_code, stderr_data.strip())

    @staticmethod
    def _extract_json_payload(output: str) -> Optional[str]:
        """Attempt to trim extra text before/after JSON payloads."""
        start_indices = [output.find(ch) for ch in ("[", "{") if output.find(ch) != -1]
        if not start_indices:
            return None
        start = min(start_indices)
        stack = []
        for idx in range(start, len(output)):
            char = output[idx]
            if char in "{[":
                stack.append("}" if char == "{" else "]")
            elif char in "}]":
                if not stack or stack[-1] != char:
                    break
                stack.pop()
                if not stack:
                    return output[start : idx + 1]
        return None

    @staticmethod
    def _find_json_start(output: str) -> int:
        for idx, char in enumerate(output):
            if char in "{[":
                return idx
            if not char.isspace():
                break
        return 0


class VastAIDeepFaceLabCLI:
    """Interactive TUI coordinating general Vast.ai workflows."""

    def __init__(self, client: VastAIClient, owner_id_override: Optional[str] = None):
        self.client = client
        self.running = True
        self.last_offers: List[Dict[str, Any]] = []
        self.last_volume_offers: Dict[str, List[Dict[str, Any]]] = {}
        self.last_templates: List[Dict[str, Any]] = []
        self._my_templates_cache: List[Dict[str, Any]] = []
        self._other_templates_cache: List[Dict[str, Any]] = []
        self._template_cache_valid = False
        self._my_template_ids: Set[str] = set()
        self._my_template_names: Set[str] = set()
        self._attempted_my_template_query = False
        self._user_id: Optional[str] = None
        self.owner_id_override = owner_id_override.strip() if owner_id_override else None

    def run(self) -> None:
        """Start the interactive loop."""
        while self.running:
            self._print_header()
            choices = [
                CLIChoice("1", "Instance management", self._handle_instances),
                CLIChoice("2", "Offer search", self._handle_offers),
                CLIChoice("3", "Template management", self._handle_templates),
                CLIChoice("4", "DeepFaceLab provisioning wizard", self._handle_provision),
                CLIChoice("5", "Exit", self._handle_exit),
            ]
            choice = prompt_choice("Select an option", choices)
            if choice:
                choice.handler()

    def _print_header(self) -> None:
        print(
            textwrap.dedent(
                """
                ==========================================
                 Vast.ai DeepFaceLab Provisioning Console
                ==========================================
                """
            ).strip()
        )

    # Placeholder handlers to be implemented in later steps.
    def _handle_instances(self) -> None:
        while True:
            print(
                textwrap.dedent(
                    """
                    \n=== Instance Management ===
                    1) List instances
                    2) Execute command on instance
                    3) Show instance logs (single fetch)
                    4) Monitor instance logs (stream)
                    5) Back
                    """
                )
            )
            selection = input("Select an option: ").strip()
            if selection == "1":
                self._list_instances()
            elif selection == "2":
                self._execute_on_instance()
            elif selection == "3":
                self._fetch_instance_logs()
            elif selection == "4":
                self._monitor_instance_logs()
            elif selection == "5" or not selection:
                return
            else:
                print("Invalid selection. Please choose 1-5.")

    def _handle_offers(self) -> None:
        print("\n=== Instance & Volume Offer Search ===\n")

        default_query = "verified=true rentable=true"
        query = prompt_text("Offer query", default=default_query)
        limit = prompt_int("Result limit", default=5, minimum=1)
        sort_by = prompt_text("Sort by (field)", default="dph_total")
        order = prompt_text("Order (asc/desc)", default="asc")

        try:
            offers = self._search_offers(query, limit=limit, sort_by=sort_by, order=order)
        except VastAICommandError as exc:
            print(f"\nFailed to fetch offers: {exc.stderr or exc}\n")
            wait_for_enter()
            return

        if not offers:
            print("No offers matched the query.\n")
            wait_for_enter()
            return

        self.last_offers = offers

        offer_lines: List[str] = []
        related_volumes: Dict[str, List[Dict[str, Any]]] = {}

        for offer in offers:
            offer_lines.extend(format_offer_summary(offer))
            machine_id = str(offer.get("machine_id", ""))
            if machine_id and machine_id not in related_volumes:
                try:
                    related_volumes[machine_id] = self._search_volumes(machine_id)
                except VastAICommandError as exc:
                    related_volumes[machine_id] = []
                    offer_lines.append(f"  volumes: error loading volumes ({exc.stderr or exc})")

            volumes = related_volumes.get(machine_id, [])
            if volumes:
                offer_lines.append(f"  volumes: {len(volumes)} matched")
                top_vol = volumes[0]
                short = format_volume_summary(top_vol)
                offer_lines.append(f"   ↳ top volume: {short}")
            else:
                offer_lines.append("  volumes: none matched")

            offer_lines.append("")  # spacer

        print("\n".join(offer_lines))
        self.last_volume_offers = related_volumes
        wait_for_enter()

    def _handle_templates(self) -> None:
        while True:
            print(
                textwrap.dedent(
                    """
                    \n=== Template Management ===
                    1) List templates
                    2) Create DeepFaceLab template
                    3) Back
                    """
                )
            )
            selection = input("Select an option: ").strip()
            if selection == "1":
                self._list_templates()
            elif selection == "2":
                self._create_template()
            elif selection == "3" or not selection:
                return
            else:
                print("Invalid selection. Please choose 1-3.")

    def _handle_provision(self) -> None:
        print("\n=== DeepFaceLab Provisioning Wizard ===\n")

        offer = self._select_offer()
        if not offer:
            return

        machine_id = str(offer.get("machine_id"))
        volume_offers = self.last_volume_offers.get(machine_id) or self._search_volumes(machine_id)
        self.last_volume_offers[machine_id] = volume_offers

        template = self._select_template()
        if not template:
            return

        volume_plan = self._configure_volume(volume_offers)
        ssh_flag = prompt_yes_no("Enable direct SSH access via --ssh flag", default=True)
        direct_flag = prompt_yes_no("Request direct port access via --direct flag", default=True)

        summary_lines = [
            "",
            "Creating instance with:",
            f"  Offer ID: {offer.get('id')} (machine {machine_id})",
            f"  Template: {template.get('name', template.get('id'))}",
        ]
        if volume_plan.mode == "link":
            summary_lines.append(f"  Linking volume {volume_plan.identifier} at {volume_plan.mount_path}")
        elif volume_plan.mode == "create":
            summary_lines.append(
                f"  Creating volume ask {volume_plan.identifier} size {volume_plan.size_gb}GB at {volume_plan.mount_path}"
            )
        else:
            summary_lines.append("  No volume attachment")
        summary_lines.append(f"  SSH flag: {'yes' if ssh_flag else 'no'}")
        summary_lines.append(f"  Direct flag: {'yes' if direct_flag else 'no'}")
        template_hash = self._ensure_template_hash(template)
        if not template_hash:
            print("\nTemplate hash is required to launch an instance from a template. Cancelling.")
            wait_for_enter()
            return
        summary_lines.append(f"  Template hash: {template_hash}")
        print("\n".join(summary_lines))
        command_args: List[str] = ["create", "instance", str(offer.get("id"))]
        command_args.extend(["--template_hash", str(template_hash)])

        if volume_plan.mode == "link":
            command_args.extend(
                ["--link-volume", str(volume_plan.identifier), "--mount-path", volume_plan.mount_path]
            )
        elif volume_plan.mode == "create":
            command_args.extend(
                [
                    "--create-volume",
                    str(volume_plan.identifier),
                    "--volume-size",
                    str(volume_plan.size_gb),
                    "--mount-path",
                    volume_plan.mount_path,
                ]
            )
            if volume_plan.label:
                command_args.extend(["--volume-label", volume_plan.label])

        if ssh_flag:
            command_args.append("--ssh")
        if direct_flag:
            command_args.append("--direct")

        command_preview = "vastai " + " ".join(shlex.quote(part) for part in command_args)
        print("\nCommand preview:\n")
        print(command_preview)
        print()

        if not prompt_yes_no("Execute this command now?", default=True):
            print("Cancelled.")
            wait_for_enter()
            return

        try:
            raw_result = self.client.run(*command_args)
        except VastAICommandError as exc:
            print(f"\nInstance creation failed: {exc.stderr or exc}\n")
            wait_for_enter()
            return

        print("\nInstance creation command executed.\n")
        result_payload = self._maybe_parse_json_payload(raw_result)

        if isinstance(result_payload, dict) and result_payload:
            for key, value in result_payload.items():
                print(f"{key}: {value}")
        elif isinstance(result_payload, list):
            for entry in result_payload:
                print(json.dumps(entry, indent=2) if isinstance(entry, dict) else entry)
        elif raw_result:
            print(raw_result)

        instance_id = self._extract_instance_id(result_payload)
        if not instance_id:
            manual = prompt_text("Enter instance id to monitor logs (leave blank to skip)", default="")
            instance_id = manual.strip() or None

        if instance_id:
            self._poll_provisioning_logs(instance_id)
        else:
            print("Instance id unavailable; skipping automatic log monitoring.")

        wait_for_enter()

    def _handle_exit(self) -> None:
        print("Goodbye!")
        self.running = False

    def _search_offers(
        self, query: str, *, limit: int, sort_by: str = "dph_total", order: str = "asc"
    ) -> List[Dict[str, Any]]:
        result = self.client.run("search", "offers", query, "--raw", capture_json=True)
        if isinstance(result, dict):
            # Some versions wrap data under "offers"
            offers = list(result.get("offers", []))
        else:
            offers = list(result or [])

        # Client-side sorting and limiting for CLI versions without --sort/--limit
        if sort_by:
            def sort_key(item: Dict[str, Any]) -> Any:
                value = item.get(sort_by)
                if isinstance(value, (int, float)):
                    return (0, value)
                if value is None:
                    return (1, "")
                return (0, str(value))

            reverse = str(order).lower() == "desc"
            offers.sort(key=sort_key, reverse=reverse)
        return offers[:limit]

    def _search_volumes(self, machine_id: str) -> List[Dict[str, Any]]:
        query = f"machine_id={machine_id}"
        result = self.client.run("search", "volumes", query, "--raw", capture_json=True)
        if isinstance(result, dict):
            return list(result.get("volumes", []))
        return list(result or [])

    def _list_templates(self) -> None:
        print("\nFetching templates...\n")
        try:
            my_templates, other_templates = self._ensure_template_cache()
        except VastAICommandError as exc:
            print(f"Failed to fetch templates: {exc.stderr or exc}")
            wait_for_enter()
            return

        if not my_templates and not other_templates:
            print("No templates found.")
            wait_for_enter()
            return

        if my_templates:
            print("My templates:")
            for template in my_templates:
                for line in format_template_summary(template):
                    print(line)
                print()
        else:
            print("You have no personal templates yet.")

        if other_templates:
            print("Community templates:")
            for template in other_templates:
                for line in format_template_summary(template):
                    suffix = "  (shared)" if self._is_my_template(template) else ""
                    print(line + suffix if suffix else line)
                print()

        wait_for_enter()

    def _fetch_all_templates(self) -> List[Dict[str, Any]]:
        result = self.client.run("search", "templates", "--raw", capture_json=True)
        return self._coerce_template_list(result)

    def _coerce_template_list(self, result: Any) -> List[Dict[str, Any]]:
        if isinstance(result, dict):
            if "templates" in result and isinstance(result["templates"], list):
                return [tpl for tpl in result["templates"] if isinstance(tpl, dict)]
            return [result]
        if isinstance(result, list):
            return [tpl for tpl in result if isinstance(tpl, dict)]
        return []

    def _remember_template(self, template: Dict[str, Any]) -> None:
        identifier = self._template_identifier(template)
        if identifier:
            self._my_template_ids.add(identifier)
        name = template.get("name")
        if name:
            self._my_template_names.add(str(name))
        hash_value = self._extract_template_hash(template)
        if hash_value:
            template["template_hash"] = hash_value

    def _template_identifier(self, template: Dict[str, Any]) -> Optional[str]:
        for key in ("id", "template_id", "hash", "uuid"):
            value = template.get(key)
            if value is not None:
                return str(value)
        name = template.get("name")
        image = template.get("image") or template.get("docker_image")
        if name or image:
            return f"{name}|{image}"
        return None

    def _ensure_user_id(self) -> Optional[str]:
        if self._user_id is not None:
            return self._user_id
        try:
            result = self.client.run("show", "user", "--raw", capture_json=True)
        except VastAICommandError:
            self._user_id = None
            return None
        if isinstance(result, dict):
            for key in ("id", "user_id", "userid"):
                if key in result:
                    self._user_id = str(result[key])
                    return self._user_id
        self._user_id = None
        return None

    def _is_my_template(self, template: Dict[str, Any]) -> bool:
        for key in ("is_owner", "mine", "owned", "is_mine", "my_template"):
            value = template.get(key)
            if isinstance(value, str):
                value = value.strip().lower() in {"true", "1", "yes", "y"}
            if value:
                return True

        identifier = self._template_identifier(template)
        if identifier and identifier in self._my_template_ids:
            return True

        name = template.get("name")
        if name and str(name) in self._my_template_names:
            return True

        user_id = self._ensure_user_id()
        if user_id is not None:
            for key in ("user_id", "owner_id", "creator_id", "created_by", "userid"):
                if str(template.get(key)) == user_id:
                    return True

        if self.owner_id_override:
            for key in ("creator_id", "owner_id", "created_by", "user_id"):
                if str(template.get(key)) == self.owner_id_override:
                    return True

        return False

    def _attempt_template_query(self, query: str) -> List[Dict[str, Any]]:
        try:
            result = self.client.run("search", "templates", query, "--raw", capture_json=True)
        except VastAICommandError:
            return []
        except RuntimeError:
            return []
        templates = self._coerce_template_list(result)
        for template in templates:
            self._remember_template(template)
        return templates

    def _collect_owner_templates(self, owner_id: str) -> List[Dict[str, Any]]:
        owner_id = owner_id.strip()
        if not owner_id:
            return []
        queries = [
            f"owner_id={owner_id}",
            f"creator_id={owner_id}",
            f"created_by={owner_id}",
            f"user_id={owner_id}",
            f"author_id={owner_id}",
        ]
        collected: List[Dict[str, Any]] = []
        seen: Set[str] = set()
        for query in queries:
            results = self._attempt_template_query(query)
            for template in results:
                identifier = self._template_identifier(template) or json.dumps(template, sort_keys=True)
                if identifier in seen:
                    continue
                seen.add(identifier)
                collected.append(template)
        return collected

    def _ensure_template_cache(self) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
        if self._template_cache_valid:
            return self._my_templates_cache, self._other_templates_cache

        initial_my_templates: List[Dict[str, Any]] = []
        if not self._attempted_my_template_query:
            self._attempted_my_template_query = True
            initial_my_templates.extend(self._attempt_template_query("my=true"))
            owner_ids_to_try: List[str] = []
            if self.owner_id_override:
                owner_ids_to_try.append(self.owner_id_override)
            user_id = self._ensure_user_id()
            if user_id:
                owner_ids_to_try.append(user_id)
            for owner_id in dict.fromkeys(owner_ids_to_try):
                initial_my_templates.extend(self._collect_owner_templates(owner_id))
            if not initial_my_templates:
                try:
                    owned_result = self.client.run("show", "templates", "--raw", capture_json=True)
                except VastAICommandError:
                    owned_result = []
                else:
                    initial_my_templates.extend(self._coerce_template_list(owned_result))

        all_templates = self._fetch_all_templates()
        my_templates: List[Dict[str, Any]] = []
        other_templates: List[Dict[str, Any]] = []
        seen: Set[str] = set()

        for template in initial_my_templates:
            identifier = self._template_identifier(template)
            if identifier:
                seen.add(identifier)
            self._remember_template(template)
            my_templates.append(template)

        for template in all_templates:
            identifier = self._template_identifier(template)
            if identifier:
                if identifier in seen:
                    continue
                seen.add(identifier)
            if self._is_my_template(template):
                self._remember_template(template)
                my_templates.append(template)
            else:
                other_templates.append(template)

        self._my_templates_cache = my_templates
        self._other_templates_cache = other_templates
        self.last_templates = my_templates + other_templates
        self._template_cache_valid = True
        return my_templates, other_templates

    def _invalidate_template_cache(self) -> None:
        self._template_cache_valid = False
        self._attempted_my_template_query = False
        self._my_templates_cache = []
        self._other_templates_cache = []
        self.last_templates = []
        self._my_template_ids.clear()
        self._my_template_names.clear()

    def _maybe_parse_json_payload(self, payload: Any) -> Any:
        if isinstance(payload, str):
            trimmed = payload.strip()
            if not trimmed:
                return payload
            try:
                return json.loads(trimmed)
            except json.JSONDecodeError:
                cleaned = self.client._extract_json_payload(trimmed)
                if cleaned:
                    try:
                        return json.loads(cleaned)
                    except json.JSONDecodeError:
                        pass
        return payload

    def _extract_template_hash(self, template: Dict[str, Any]) -> Optional[str]:
        hash_keys = [
            "template_hash",
            "hash",
            "hash_id",
            "templateHash",
            "hashId",
        ]
        for key in hash_keys:
            value = template.get(key)
            if value:
                value_str = str(value).strip()
                if value_str:
                    template["template_hash"] = value_str
                    return value_str
        nested = template.get("template") or template.get("data")
        if isinstance(nested, dict):
            nested_hash = self._extract_template_hash(nested)
            if nested_hash:
                template["template_hash"] = nested_hash
                return nested_hash
        return None

    def _ensure_template_hash(self, template: Dict[str, Any]) -> Optional[str]:
        existing = self._extract_template_hash(template)
        if existing:
            return existing

        search_queries: List[str] = []
        template_id = template.get("id") or template.get("template_id")
        if template_id:
            search_queries.append(f"id={template_id}")
        template_name = template.get("name")
        if template_name:
            escaped_name = template_name.replace('"', '\\"')
            search_queries.append(f'name="{escaped_name}"')

        owner_ids = []
        if self.owner_id_override:
            owner_ids.append(self.owner_id_override)
        user_id = self._ensure_user_id()
        if user_id:
            owner_ids.append(user_id)

        for owner_id in dict.fromkeys(owner_ids):
            search_queries.append(f"creator_id={owner_id}")
            search_queries.append(f"owner_id={owner_id}")

        for query in search_queries:
            if not query:
                continue
            try:
                result = self.client.run("search", "templates", query, "--raw", capture_json=True)
            except VastAICommandError:
                continue
            entries = self._coerce_template_list(result)
            for entry in entries:
                hash_value = self._extract_template_hash(entry)
                if hash_value:
                    template.update(entry)
                    self._remember_template(template)
                    return hash_value

        while True:
            manual = prompt_text("Template hash (required, leave blank to cancel)")
            manual = manual.strip()
            if not manual:
                confirm_cancel = prompt_yes_no("Hash still missing. Cancel instance creation?", default=True)
                if confirm_cancel:
                    return None
                continue
            template["template_hash"] = manual
            self._remember_template(template)
            return manual

    def _create_template(self) -> None:
        print("\n=== Create DeepFaceLab Template ===")
        default_name = "DeepFaceLab Desktop"
        default_image = "mannyj37/dfl-desktop:latest"
        default_env = (
            "-p 5901 -p 11111 "
            "-e VNC_PASSWORD=deepfacelab "
            "-e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh"
        )
        default_disk_space = 50

        name = prompt_text("Template name", default=default_name)
        image = prompt_text("Docker image", default=default_image)
        env = prompt_text("Docker env/ports string (--env)", default=default_env)
        disk_space = prompt_int("Container disk space (GB)", default=default_disk_space, minimum=10)

        extra_flags = prompt_text("Additional Vast.ai CLI flags (optional)", default="")
        confirm = prompt_yes_no(
            textwrap.dedent(
                f"""
                About to run:
                  vastai create template \\
                    --name {name!r} \\
                    --image {image!r} \\
                    --env {env!r} \\
                    --disk_space {disk_space} {extra_flags}
                Proceed?
                """
            ).strip()
        )
        if not confirm:
            print("Template creation cancelled.")
            wait_for_enter()
            return

        args: List[str] = [
            "create",
            "template",
            "--name",
            name,
            "--image",
            image,
            "--env",
            env,
            "--disk_space",
            str(disk_space),
        ]
        if extra_flags:
            args.extend(shlex.split(extra_flags))

        try:
            result = self.client.run(*args, capture_json=True)
        except VastAICommandError as exc:
            print(f"\nTemplate creation failed: {exc.stderr or exc}\n")
            wait_for_enter()
            return

        print("\nTemplate created successfully!\n")
        template_record: Optional[Dict[str, Any]] = None
        parsed_result = self._maybe_parse_json_payload(result)

        if isinstance(parsed_result, dict):
            template_record = parsed_result
            for key, value in parsed_result.items():
                print(f"{key}: {value}")
        elif isinstance(parsed_result, list):
            for entry in parsed_result:
                if isinstance(entry, dict):
                    if template_record is None:
                        template_record = entry
                    print(json.dumps(entry, indent=2))
                else:
                    print(entry)
        else:
            if result:
                print(result)

        if template_record:
            self._remember_template(template_record)
        else:
            self._remember_template({"name": name})

        self._invalidate_template_cache()
        print("\nNote: Vast.ai templates do not accept a description flag; store notes externally if needed.")
        wait_for_enter()

    def _list_instances(self) -> None:
        print("\nFetching instances...\n")
        try:
            instances = self._fetch_instances()
        except VastAICommandError as exc:
            print(f"Failed to fetch instances: {exc.stderr or exc}")
            wait_for_enter()
            return
        if not instances:
            print("No instances found.")
            wait_for_enter()
            return
        for inst in instances:
            for line in format_instance_summary(inst):
                print(line)
            print()
        wait_for_enter()

    def _fetch_instances(self) -> List[Dict[str, Any]]:
        result = self.client.run("show", "instances", "--raw", capture_json=True)
        if isinstance(result, dict):
            return list(result.get("instances", []))
        return list(result or [])

    def _execute_on_instance(self) -> None:
        instance_id = prompt_text("Instance ID")
        command = prompt_text("Command to execute (bash snippet)")
        if not instance_id or not command:
            print("Instance ID and command are required.")
            wait_for_enter()
            return
        try:
            output = self.client.run("execute", str(instance_id), "--cmd", command)
        except VastAICommandError as exc:
            print(f"\nCommand failed: {exc.stderr or exc}\n")
            wait_for_enter()
            return
        print("\nCommand output:\n")
        print(output)
        wait_for_enter()

    def _fetch_instance_logs(self) -> None:
        instance_id = prompt_text("Instance ID")
        if not instance_id:
            return
        try:
            logs = self.client.run("logs", str(instance_id))
        except VastAICommandError as exc:
            print(f"\nFailed to fetch logs: {exc.stderr or exc}\n")
            wait_for_enter()
            return
        print("\nInstance logs:\n")
        print(logs)
        wait_for_enter()

    def _monitor_instance_logs(self) -> None:
        instance_id = prompt_text("Instance ID")
        if not instance_id:
            return
        print("Streaming logs. Press Ctrl+C to stop.\n")
        provisioning_detected = False
        stream_iter = self.client.stream("logs", str(instance_id), "--follow")
        try:
            for line in stream_iter:
                print(line)
                if "=== Provisioning Complete ===" in line:
                    provisioning_detected = True
        except VastAICommandError as exc:
            print(f"\nStreaming ended with error: {exc.stderr or exc}\n")
        except KeyboardInterrupt:
            print("\nStopped log streaming.")
        finally:
            if hasattr(stream_iter, "close"):
                stream_iter.close()
            if provisioning_detected:
                print("✅ DeepFaceLab provisioning completed successfully.")
            else:
                print("⚠️ Provisioning completion line not detected; review logs above.")
            wait_for_enter()

    def _poll_provisioning_logs(self, instance_id: str) -> None:
        print(f"\nMonitoring provisioning logs for instance {instance_id}...\n")
        provisioning_detected = False
        stream_iter = self.client.stream("logs", str(instance_id), "--follow")
        try:
            for line in stream_iter:
                print(line)
                if "=== Provisioning Complete ===" in line:
                    provisioning_detected = True
                    print("\n✅ Provisioning script reported completion. Stopping log stream.\n")
                    break
        except VastAICommandError as exc:
            print(f"\nLog streaming failed: {exc.stderr or exc}\n")
        except KeyboardInterrupt:
            print("\nLog monitoring interrupted by user.")
        finally:
            if hasattr(stream_iter, "close"):
                stream_iter.close()
            if not provisioning_detected:
                print(
                    "⚠️ Provisioning completion marker not detected. "
                    "Use 'Instance management → Monitor logs' to continue checking."
                )

    def _extract_instance_id(self, payload: Any) -> Optional[str]:
        if payload is None:
            return None
        if isinstance(payload, dict):
            candidates = [
                "instance_id",
                "id",
                "contract_id",
                "new_instance_id",
                "new_contract_id",
            ]
            for key in candidates:
                candidate: Optional[str] = None
                value = payload.get(key)
                if isinstance(value, (int, str)):
                    value_str = str(value).strip()
                    if value_str.isdigit():
                        if key != "id" or payload.get("type") == "instance" or "instance" in payload.get("status", ""):
                            return value_str
                        # Prefer instance-specific keys; continue search otherwise
                        candidate = value_str
                    else:
                        candidate = None
                else:
                    candidate = None
                if key == "id" and candidate:
                    return candidate

            for nested_key in ("instance", "new_contract", "data", "result"):
                nested = payload.get(nested_key)
                if nested is not None:
                    extracted = self._extract_instance_id(nested)
                    if extracted:
                        return extracted

            for value in payload.values():
                if isinstance(value, (dict, list)):
                    extracted = self._extract_instance_id(value)
                    if extracted:
                        return extracted

        if isinstance(payload, list):
            for item in payload:
                extracted = self._extract_instance_id(item)
                if extracted:
                    return extracted

        if isinstance(payload, str):
            match = re.search(r"(?:instance_id|instance|contract_id|id)\D*(\d+)", payload)
            if match:
                return match.group(1)
        return None

    def _select_offer(self) -> Optional[Dict[str, Any]]:
        if not self.last_offers:
            print("No offers loaded yet. Running default search...")
            try:
                self.last_offers = self._search_offers("verified=true rentable=true", limit=5)
            except VastAICommandError as exc:
                print(f"Unable to load offers: {exc.stderr or exc}")
                wait_for_enter()
                return None
        if not self.last_offers:
            print("No offers available.")
            wait_for_enter()
            return None
        index = prompt_select_from_list(
            self.last_offers,
            label_fn=lambda offer: f"{offer.get('id')} | {offer.get('gpu_name')} | ${offer.get('dph_total')}/hr | machine {offer.get('machine_id')}",
            header="Select an instance offer",
        )
        if index is None:
            return None
        return self.last_offers[int(index)]

    def _select_template(self) -> Optional[Dict[str, Any]]:
        show_all = False
        while True:
            try:
                my_templates, other_templates = self._ensure_template_cache()
            except VastAICommandError as exc:
                print(f"Unable to load templates: {exc.stderr or exc}")
                wait_for_enter()
                return None

            if not my_templates and not other_templates:
                print("No templates available.")
                if prompt_yes_no("Create a new template now?", default=True):
                    self._create_template()
                    self._invalidate_template_cache()
                    continue
                return None

            if not my_templates:
                show_all = True

            refresh_needed = False
            while True:
                if show_all:
                    items = my_templates + other_templates
                    header = "Select a template (your templates are listed first)"
                    extra_options: Dict[str, str] = {}
                    if my_templates:
                        extra_options["M"] = "Show only your templates"
                else:
                    items = my_templates
                    header = "Select one of your templates"
                    extra_options = {}
                    if other_templates:
                        extra_options["A"] = "Browse community templates"

                extra_options["C"] = "Create new template"

                label_fn = (
                    (lambda tpl: format_template_option(tpl, owned=self._is_my_template(tpl)))
                    if show_all
                    else (lambda tpl: format_template_option(tpl, owned=True))
                )

                index = prompt_select_from_list(
                    items,
                    label_fn=label_fn,
                    header=header,
                    extra_options=extra_options,
                )

                if isinstance(index, str):
                    choice = index.upper()
                    if choice == "A":
                        show_all = True
                        continue
                    if choice == "M":
                        show_all = False
                        continue
                    if choice == "C":
                        self._create_template()
                        self._invalidate_template_cache()
                        refresh_needed = True
                        break
                    return None

                if index is None:
                    return None

                try:
                    return items[int(index)]
                except (IndexError, ValueError):
                    print("Invalid selection. Please try again.")

            if refresh_needed:
                show_all = False
                continue

    def _configure_volume(self, volume_offers: List[Dict[str, Any]]) -> "VolumePlan":
        print("\nVolume options:")
        print("1) Create new volume from offers")
        print("2) Link existing personal volume")
        print("3) No volume")
        choice = input("Select volume option [1]: ").strip() or "1"
        if choice == "1" and volume_offers:
            idx = prompt_select_from_list(
                volume_offers,
                label_fn=lambda vol: f"ask {vol.get('id')} | size {vol.get('size')}GB | price ${vol.get('price')}/mo",
                header="Select a volume ask",
            )
            if idx is None:
                return VolumePlan.none()
            volume_offer = volume_offers[idx]
            size = prompt_int("Volume size (GB)", default=int(volume_offer.get("size", 200)), minimum=10)
            label = prompt_text("Volume label", default="dfl_workspace")
            mount = prompt_text("Mount path", default="/workspace")
            return VolumePlan.create(identifier=volume_offer.get("id"), size_gb=size, label=label, mount_path=mount)
        if choice == "2":
            vol_id = prompt_text("Existing volume ID")
            mount = prompt_text("Mount path", default="/workspace")
            return VolumePlan.link(identifier=vol_id, mount_path=mount)
        return VolumePlan.none()


def prompt_choice(prompt: str, choices: Iterable[CLIChoice]) -> Optional[CLIChoice]:
    """Prompt the user to select among choices."""
    choice_map: Dict[str, CLIChoice] = {}
    for entry in choices:
        print(f"[{entry.key}] {entry.label}")
        choice_map[entry.key] = entry
    selection = input(f"{prompt}: ").strip()
    return choice_map.get(selection)


def prompt_text(prompt: str, default: Optional[str] = None) -> str:
    suffix = f" [{default}]" if default else ""
    response = input(f"{prompt}{suffix}: ").strip()
    if not response and default is not None:
        return default
    return response


def prompt_int(prompt: str, default: Optional[int] = None, minimum: Optional[int] = None) -> int:
    while True:
        suffix = f" [{default}]" if default is not None else ""
        raw = input(f"{prompt}{suffix}: ").strip()
        if not raw and default is not None:
            value = default
        else:
            try:
                value = int(raw)
            except ValueError:
                print("Please enter a valid integer.")
                continue
        if minimum is not None and value < minimum:
            print(f"Value must be at least {minimum}.")
            continue
        return value


def prompt_yes_no(prompt: str, default: bool = True) -> bool:
    default_char = "Y/n" if default else "y/N"
    while True:
        response = input(f"{prompt} ({default_char}): ").strip().lower()
        if not response:
            return default
        if response in {"y", "yes"}:
            return True
        if response in {"n", "no"}:
            return False
        print("Please answer with y or n.")


def format_offer_summary(offer: Dict[str, Any]) -> List[str]:
    offer_id = offer.get("id")
    machine_id = offer.get("machine_id")
    gpu_name = offer.get("gpu_name", "unknown")
    dph = offer.get("dph_total", offer.get("price", "n/a"))
    cuda = offer.get("cuda_max_good", "n/a")
    score = offer.get("score", "n/a")
    storage_total = offer.get("storage_total", "n/a")
    lines = [
        f"Offer {offer_id} (machine {machine_id})",
        f"  gpu: {gpu_name} | dph_total: {dph} | cuda: {cuda} | score: {score}",
        f"  storage_total: {storage_total} GiB",
    ]
    return lines


def format_volume_summary(volume: Dict[str, Any]) -> str:
    vol_id = volume.get("id", "n/a")
    size = volume.get("size", "n/a")
    price = volume.get("price", "n/a")
    region = volume.get("region", "n/a")
    return f"id={vol_id} size={size}GB price=${price}/mo region={region}"


def format_template_summary(template: Dict[str, Any]) -> List[str]:
    template_id = template.get("id")
    name = template.get("name", "unnamed")
    image = template.get("image", template.get("docker_image", "unknown"))
    disk = template.get("disk", template.get("disk_space", "n/a"))
    created = template.get("dt_created", template.get("created_on", "n/a"))
    description = template.get("description", "")
    owner = (
        template.get("creator_id")
        or template.get("owner_id")
        or template.get("created_by")
        or template.get("user_id")
    )
    hash_value = template.get("template_hash") or template.get("hash")
    lines = [
        f"Template {template_id}: {name}",
        f"  image: {image} | disk_space: {disk}GB | created: {created}",
    ]
    if owner:
        lines.append(f"  owner_id: {owner}")
    if hash_value:
        lines.append(f"  hash: {hash_value}")
    if description:
        lines.append(f"  description: {description}")
    return lines


def format_template_option(template: Dict[str, Any], owned: bool = False) -> str:
    name = template.get("name", "unnamed")
    image = template.get("image", template.get("docker_image", "unknown"))
    disk = template.get("disk_space", template.get("disk", "n/a"))
    template_id = template.get("id") or template.get("template_id")
    hash_value = template.get("template_hash") or template.get("hash")
    visibility = template.get("visibility")
    if visibility:
        visibility = str(visibility)
    elif template.get("public"):
        visibility = "public"
    if owned:
        marker = "[yours]"
    elif visibility:
        marker = f"[{visibility}]"
    else:
        marker = "[shared]"
    base = f"{name}"
    if template_id:
        base += f" (id {template_id})"
    base += f" | image: {image} | disk: {disk}GB"
    if hash_value:
        base += f" | hash: {hash_value}"
    return f"{base} {marker}".strip()


def format_instance_summary(instance: Dict[str, Any]) -> List[str]:
    inst_id = instance.get("id")
    status = instance.get("actual_status", instance.get("status"))
    machine_id = instance.get("machine_id")
    offer_id = instance.get("offer_id")
    template_name = instance.get("template_name") or instance.get("template")
    ip_addr = instance.get("public_ip")
    ssh_port = instance.get("ssh_port")
    lines = [
        f"Instance {inst_id} (offer {offer_id}, machine {machine_id})",
        f"  status: {status} | template: {template_name}",
    ]
    if ip_addr or ssh_port:
        lines.append(f"  connection: {ip_addr}:{ssh_port}")
    return lines


def prompt_select_from_list(
    items: Sequence[Any],
    *,
    label_fn: Callable[[Any], str],
    header: str,
    extra_options: Optional[Dict[str, str]] = None,
) -> Optional[Union[int, str]]:
    if not items:
        print("No items available.")
        return None
    print(f"\n{header}")
    for idx, item in enumerate(items, start=1):
        print(f"  {idx}) {label_fn(item)}")
    if extra_options:
        for key, label in extra_options.items():
            print(f"  {key}) {label}")
    print("  Q) Cancel")

    while True:
        choice = input("Select an option: ").strip()
        if not choice:
            choice = "1"
        if choice.lower() in {"q", "quit", "exit"}:
            return None
        if extra_options and choice in extra_options:
            return choice
        try:
            position = int(choice)
        except ValueError:
            print("Please enter a valid option.")
            continue
        if 1 <= position <= len(items):
            return position - 1
        print("Selection out of range. Try again.")


def wait_for_enter(message: str = "Press Enter to continue...") -> None:
    """Wait for user acknowledgement."""
    try:
        input(message)
    except KeyboardInterrupt:
        print()


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Interactive Vast.ai DeepFaceLab provisioning CLI.")
    parser.add_argument(
        "--vastai-binary",
        default="vastai",
        help="Path to the vastai CLI executable (default: %(default)s)",
    )
    parser.add_argument(
        "--api-key",
        default=None,
        help="Optional Vast.ai API key (falls back to VAST_API_KEY env var).",
    )
    parser.add_argument(
        "--owner-id",
        default=os.environ.get("VAST_OWNER_ID"),
        help="Optional owner/creator id for filtering personal templates (env: VAST_OWNER_ID).",
    )
    parser.add_argument(
        "--print-readme",
        action="store_true",
        help="Print usage overview and exit.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.print_readme:
        print(README_SNIPPET)
        return 0
    client = VastAIClient(binary=args.vastai_binary, api_key=args.api_key)
    app = VastAIDeepFaceLabCLI(client, owner_id_override=args.owner_id)
    try:
        app.run()
        return 0
    except VastAICommandError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        if exc.stderr:
            print(exc.stderr, file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:
        print("\nInterrupted by user.")
        return 130


if __name__ == "__main__":
    sys.exit(main())

