#!/usr/bin/env python3
"""Assert that one rendered devcontainer tree matches its Copier answers.

Invoked once per answer set by ``scripts/test-render.sh``. The expected
answers are passed as a JSON spec file (path as the sole argv). Every check is
run and printed (so a CI log shows exactly what passed); the script exits
non-zero if any of them failed.

Run it through ``uv run --with pyyaml python`` so PyYAML is available without a
project virtualenv (this template repo has no Python package of its own).
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

ANSWERS_FILE = ".devcontainer/.copier-answers.devcontainer.yml"


class Checker:
    """Accumulates pass/fail lines so the whole render is reported at once."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.failures: list[str] = []

    def check(self, condition: bool, label: str, detail: str = "") -> None:
        mark = "PASS" if condition else "FAIL"
        line = f"  [{mark}] {label}"
        if not condition and detail:
            line += f"\n         -> {detail}"
        print(line)
        if not condition:
            self.failures.append(label)


def slugify(name: str) -> str:
    """Re-implement the Compose-name slug rule from docker-compose.yml.jinja.

    Kept deliberately independent of the template so a regression in the Jinja
    expression is caught by a mismatch rather than silently mirrored.
    """
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower())
    slug = re.sub(r"^-+|-+$", "", slug)
    return (slug or "devcontainer") + "_devcontainer"


def strip_jsonc(text: str) -> str:
    """Drop // line comments and /* */ block comments so json.loads accepts it.

    devcontainer.json is JSONC. We strip rather than pull in a JSON5 parser; the
    template uses no trailing commas, so plain json suffices after stripping.
    String literals here contain no // or /* sequences, so a naive strip is safe.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.MULTILINE)
    return text


def extract_allowed_hosts(script: str) -> list[str]:
    """Pull the ALLOWED_HOSTS=( ... ) bash array entries from init-firewall.sh.

    Entries are rendered one per line, unquoted (e.g. ``    api.anthropic.com``),
    so split on whitespace rather than matching quoted strings; tolerate quotes
    in case the rendering ever changes.
    """
    m = re.search(r"ALLOWED_HOSTS=\((.*?)\)", script, flags=re.DOTALL)
    if m is None:
        return []
    return [
        tok.strip("\"'")
        for tok in m.group(1).split()
        if not tok.startswith("#")
    ]


def templated_outputs(template_dir: Path) -> set[str]:
    """Rendered paths that came from a ``.jinja`` source.

    The leftover-Jinja sweep must only cover these: files copied verbatim
    (the template's narrow-surface rule) legitimately contain brace sequences
    — e.g. ``%{%}`` in .p10k.zsh — and were never meant to be rendered.
    """
    outputs: set[str] = set()
    for p in template_dir.rglob("*.jinja"):
        rel = p.relative_to(template_dir).as_posix()[: -len(".jinja")]
        # The answers-file template's own name is Jinja
        # ("{{ _copier_conf.answers_file }}.jinja"); it renders to ANSWERS_FILE.
        if "{{" in rel or "{%" in rel:
            rel = ANSWERS_FILE
        outputs.add(rel)
    return outputs


def main() -> int:
    spec = json.loads(Path(sys.argv[1]).read_text())
    root = Path(spec["dir"])
    project_name: str = spec["project_name"]
    gitignore: bool = spec["gitignore_devcontainer"]

    # A null allowed_domains means "the defaults case": resolve the expected
    # list from copier.yml so the default set is verified without duplicating
    # (and rotting) it here.
    allowed_domains = spec["allowed_domains"]
    if allowed_domains is None:
        cfg = yaml.safe_load(Path(spec["copier_yml"]).read_text())
        allowed_domains = cfg["allowed_domains"]["default"]

    c = Checker(root)
    print(f"Checking render: {spec['label']}  ({root})")

    # --- answers file landed at the dedicated path (so `copier update` works) ---
    answers = root / ANSWERS_FILE
    c.check(answers.is_file(), f"answers file at {ANSWERS_FILE}")

    # --- devcontainer.json: valid JSONC, name == project_name ---
    dcj = root / ".devcontainer/devcontainer.json"
    try:
        data = json.loads(strip_jsonc(dcj.read_text()))
        c.check(True, "devcontainer.json is valid JSONC")
        c.check(
            data.get("name") == project_name,
            'devcontainer.json "name" == project_name',
            f'got {data.get("name")!r}, expected {project_name!r}',
        )
    except Exception as exc:  # noqa: BLE001 - report any parse failure as a check
        c.check(False, "devcontainer.json is valid JSONC", str(exc))

    # --- docker-compose.yml: valid YAML, name == slug(project_name) ---
    compose = root / ".devcontainer/docker-compose.yml"
    expected_slug = slugify(project_name)
    try:
        cdata = yaml.safe_load(compose.read_text())
        c.check(True, "docker-compose.yml is valid YAML")
        name = cdata.get("name")
        c.check(
            name == expected_slug,
            f"compose name == {expected_slug!r}",
            f"got {name!r}",
        )
        c.check(
            bool(re.fullmatch(r"[a-z0-9][a-z0-9_-]*", str(name))),
            "compose name is a valid lowercased slug",
            f"got {name!r}",
        )
    except Exception as exc:  # noqa: BLE001
        c.check(False, "docker-compose.yml is valid YAML", str(exc))

    # --- init-firewall.sh: ALLOWED_HOSTS matches the answer ---
    fw = root / ".devcontainer/init-firewall.sh"
    hosts = extract_allowed_hosts(fw.read_text())
    c.check(
        hosts == allowed_domains,
        "init-firewall ALLOWED_HOSTS matches allowed_domains",
        f"got {hosts}, expected {allowed_domains}",
    )

    # --- Dockerfile: headless-browser block present iff the answer is true ---
    # Skipped (None) for renders that don't pin install_headless_browser.
    install_browser = spec.get("install_headless_browser")
    if install_browser is not None:
        dockerfile = (root / ".devcontainer/Dockerfile").read_text()
        has_block = "playwright install chromium" in dockerfile
        c.check(
            has_block == install_browser,
            f"Dockerfile browser block present == {install_browser}",
            f"present={has_block}",
        )

    # --- .gitignore: '*' when ignoring the folder, '.env' when tracking it ---
    gi = root / ".devcontainer/.gitignore"
    gi_lines = [
        ln.strip()
        for ln in gi.read_text().splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    expected_gi = ["*"] if gitignore else [".env"]
    c.check(
        gi_lines == expected_gi,
        f".devcontainer/.gitignore is {expected_gi}",
        f"got {gi_lines}",
    )

    # --- every rendered shell script parses (the {% raw %} wrap must be intact) ---
    sh_files = [
        p
        for p in root.rglob("*")
        if p.is_file() and (p.suffix == ".sh" or p.parent.name == "bin")
    ]
    for p in sorted(sh_files):
        res = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
        c.check(res.returncode == 0, f"bash -n {p.relative_to(root)}", res.stderr.strip())

    # --- no leftover Jinja in files rendered from .jinja sources ---
    outputs = templated_outputs(Path(spec["template_dir"]))
    leftovers: list[str] = []
    for rel in sorted(outputs):
        p = root / rel
        if not p.is_file():
            continue
        body = p.read_text()
        if "{{" in body or "{%" in body:
            leftovers.append(rel)
    c.check(not leftovers, "no leftover Jinja tags in rendered .jinja outputs", f"in: {leftovers}")

    if c.failures:
        print(f"\n{len(c.failures)} check(s) FAILED for '{spec['label']}'")
        return 1
    print(f"All checks passed for '{spec['label']}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
