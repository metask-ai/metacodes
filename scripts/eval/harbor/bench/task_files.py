from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass, field
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
KEY = r"(" + QUOTED + r"""|[^\s"'{\[].*?)\s*:"""
FLOW_PAIR = re.compile(KEY + r"\s*(.*)")
BLOCK_PAIR = re.compile(KEY + r"(?:\s+(.*)|$)")
COMMENT = re.compile(QUOTED + r"|(?<!\S)#[^\n]*")
ANCHOR = re.compile(r"&([^\s,\[\]{}]+)(?:\s+|$)")
DOCUMENT_LINE = re.compile(r"^(?:%.*|(?:---|\.\.\.)\s*(?:#.*)?)$")


def flow_items(value: str, lines) -> Iterator[str]:
    parts = []
    depth = 1
    quote = ""
    escaped = False
    line = value[1:]
    while True:
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
        if not lines:
            return
        line = lines.popleft()


def put(mapping, key, value):
    if key == "<<":
        for base in value if isinstance(value, list) else [value]:
            if isinstance(base, dict):
                for name, item in base.items():
                    mapping.setdefault(name, item)
    else:
        mapping[key.strip("\"'")] = value


def indent(line):
    return len(line) - len(line.lstrip())


def list_item(text):
    return text == "-" or text.startswith("- ")


def compose_value(text, anchors, lines=(), parent_indent=None):
    anchor = ANCHOR.match(text)
    if anchor:
        text = text[anchor.end():]
    if not text or text.startswith("#"):
        value = None
        if lines and parent_indent is not None:
            depth = indent(lines[0])
            if depth > parent_indent or (depth == parent_indent and list_item(lines[0].lstrip())):
                value = compose_block(lines, anchors)
    elif text.startswith("{"):
        value = {}
        for item in flow_items(text, lines):
            pair = FLOW_PAIR.fullmatch(item)
            if pair:
                put(value, pair[1], compose_value(pair[2], anchors))
    elif text.startswith("["):
        value = [compose_value(item, anchors) for item in flow_items(text, lines)]
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


def compose_block(lines, anchors, *, root=False):
    depth = indent(lines[0])
    first = lines[0].lstrip()
    sequence = list_item(first)
    if first.startswith("{") or (not root and not sequence and not BLOCK_PAIR.fullmatch(first)):
        return compose_value(lines.popleft().strip(), anchors, lines, depth)
    block = [] if sequence else {}
    while lines and indent(lines[0]) >= depth:
        line = lines[0].lstrip()
        if indent(lines[0]) > depth:
            lines.popleft()
            continue
        if sequence != list_item(line):
            break
        lines.popleft()
        if sequence:
            block.append(compose_value(line[1:].strip(), anchors, lines, depth))
        else:
            pair = BLOCK_PAIR.fullmatch(line)
            if pair:
                put(block, pair[1], compose_value(pair[2] or "", anchors, lines, depth))
    return block


def compose_services(text: str) -> Iterator[Service]:
    lines = deque(line.rstrip() for line in text.splitlines()
                  if line.strip() and not line.lstrip().startswith("#") and not DOCUMENT_LINE.fullmatch(line))
    root = compose_block(lines, {}, root=True) if lines else {}
    services = root.get("services") if isinstance(root, dict) else None
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
        text = text.removeprefix("\ufeff")
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
