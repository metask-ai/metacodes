from __future__ import annotations

import re
from dataclasses import dataclass, field
from itertools import chain
from pathlib import Path
from typing import Iterable, Iterator, Optional


@dataclass
class Service:
    name: str
    image: Optional[str]
    build: bool


@dataclass
class TaskReferences:
    environment_image: Optional[str] = None
    other_images: list[str] = field(default_factory=list)
    services: list[Service] = field(default_factory=list)

    def images(self, *, include_builds: bool) -> Iterator[str]:
        if self.environment_image:
            yield self.environment_image
        yield from self.other_images
        for service in self.services:
            if service.image and (include_builds or not service.build):
                yield service.image


def sources(root: Path, *, compose_only=False, dockerfile_suffix=True) -> Iterator[tuple[str, str]]:
    for path in sorted(root.rglob("*")):
        name = path.name.lower()
        if not compose_only and (name.startswith("dockerfile") or (dockerfile_suffix and name.endswith(".dockerfile"))):
            kind = "dockerfile"
        elif "compose" in name and name.endswith((".yaml", ".yml")):
            kind = "compose"
        elif not compose_only and name == "task.toml":
            kind = "toml"
        else:
            continue
        if path.is_file() and not path.is_symlink():
            try:
                yield kind, path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue


def pull_sources(task: Path) -> Iterator[tuple[str, str]]:
    try:
        yield "toml", (task / "task.toml").read_text(encoding="utf-8")
    except OSError:
        raise ValueError("任务缺少 task.toml：" + task.name) from None
    try:
        yield "compose", (task / "environment/docker-compose.yaml").read_text(encoding="utf-8")
    except OSError:
        return


QUOTED = r'''(?:"(?:\\.|[^"\\])*"|'(?:''|[^'])*')'''
PAIR = re.compile(r"(" + QUOTED + r"|[\w.<>-]+)\s*:\s*(.*)")
COMMENT = re.compile(QUOTED + r"|(?<!\S)#[^\n]*")
ANCHOR = re.compile(r"&([^\s,\[\]{}]+)(?:\s+|$)")


def flow_items(value: str, lines: Iterator[str]) -> Iterator[str]:
    parts = []
    depth = 1
    quote = ""
    escaped = False
    for line in chain((value[1:],), lines):
        start = 0
        for index, char in enumerate(line):
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\" and quote == '"':
                    escaped = True
                elif char == quote:
                    quote = ""
                continue
            if char in "\"'" and (index == 0 or line[index - 1] in " \t[{,:\"'"):
                quote = char
            elif char == "#" and (index == 0 or line[index - 1].isspace()):
                line = line[:index]
                break
            elif char in "{[":
                depth += 1
            elif char in "}]":
                depth -= 1
            if depth == 0 or (depth == 1 and char == ","):
                parts.append(line[start:index])
                yield " ".join(parts).strip()
                if depth == 0:
                    return
                parts = []
                start = index + 1
        parts.append(line[start:])
        escaped = False


def put(mapping, key, value):
    if key == "<<":
        for base in value if isinstance(value, list) else [value]:
            if isinstance(base, dict):
                for name, item in base.items():
                    mapping.setdefault(name, item)
    else:
        mapping[key.strip("\"'")] = value


def compose_value(text, anchors, lines):
    anchor = ANCHOR.match(text)
    if anchor:
        text = text[anchor.end():]
    if not text or text.startswith("#"):
        value = {}
    elif text.startswith("{"):
        value = {}
        for item in flow_items(text, lines):
            pair = PAIR.fullmatch(item)
            if pair:
                put(value, pair[1], compose_value(pair[2], anchors, iter(())))
    elif text.startswith("["):
        value = [compose_value(item, anchors, iter(())) for item in flow_items(text, lines)]
    else:
        comment = next((m.start() for m in COMMENT.finditer(text) if m[0].startswith("#")), len(text))
        scalar = text[:comment].rstrip()
        if scalar.startswith("*"):
            value = anchors.get(scalar[1:])
        else:
            value = scalar[1:-1] if re.fullmatch(QUOTED, scalar) else scalar
    if anchor:
        anchors[anchor[1]] = value
    return value


def compose_services(text: str) -> Iterator[Service]:
    root, anchors = {}, {}
    parents = [(-1, root)]
    lines = iter(text.splitlines())
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        depth = len(line) - len(stripped)
        while depth <= parents[-1][0]:
            parents.pop()
        parent = parents[-1][1]
        pair = PAIR.fullmatch(stripped)
        if isinstance(parent, dict) and stripped.startswith("{"):
            parent.update(compose_value(stripped, anchors, lines))
        elif isinstance(parent, dict) and pair:
            value = compose_value(pair[2], anchors, lines)
            put(parent, pair[1], value)
            parents.append((depth, value))
        else:
            parents.append((depth, None))
    services = root.get("services")
    if isinstance(services, dict):
        for name, config in services.items():
            config = config if isinstance(config, dict) else {}
            image = config.get("image")
            yield Service(name, image if isinstance(image, str) else None, "build" in config)


SECTION = re.compile(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*(?:#.*)?$")
TOML_IMAGE = re.compile(r"""^\s*(?:docker_image|"docker_image"|'docker_image')\s*=\s*(?:"([^"]+)"|'([^']+)')""")
FROM_LINE = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)", re.I | re.M)


def references(files: Iterable[tuple[str, str]]) -> TaskReferences:
    task = TaskReferences()
    for kind, text in files:
        if kind == "compose":
            task.services.extend(compose_services(text))
        elif kind == "dockerfile":
            task.other_images.extend(FROM_LINE.findall(text))
        else:
            section = ""
            for line in text.splitlines():
                header = SECTION.match(line)
                if header:
                    section = header[1].strip("\"'")
                image = TOML_IMAGE.match(line)
                if image:
                    ref = image[1] or image[2]
                    if section == "environment" and task.environment_image is None:
                        task.environment_image = ref
                    else:
                        task.other_images.append(ref)
    return task
