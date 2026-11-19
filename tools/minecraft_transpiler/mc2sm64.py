#!/usr/bin/env python3
"""Conservative Java-to-SM64CoopDX transpiler.

This is a source-to-source compiler for a deliberately small, auditable Java
subset. Unsupported constructs are reported and the affected method is not emitted.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    from tree_sitter import Language, Parser
    import tree_sitter_java
except ImportError as exc:
    raise SystemExit(
        "Missing dependencies. Run: python -m pip install -r "
        "tools/minecraft_transpiler/requirements.txt"
    ) from exc


def make_parser() -> Parser:
    capsule = tree_sitter_java.language()
    try:
        language = Language(capsule, "java")
    except TypeError:
        language = Language(capsule)
    try:
        return Parser(language)
    except TypeError:
        parser = Parser()
        if hasattr(parser, "set_language"):
            parser.set_language(language)
        else:
            parser.language = language
        return parser


PRIMITIVE_C_TYPES = {
    "void": "void", "boolean": "bool", "byte": "int8_t",
    "short": "int16_t", "int": "int32_t", "long": "int64_t",
    "float": "float", "double": "double", "char": "char",
}
LUA_RESERVED = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}


@dataclass
class Diagnostic:
    severity: str
    code: str
    message: str
    source: str
    line: int

    def as_dict(self) -> dict[str, Any]:
        return {
            "severity": self.severity, "code": self.code,
            "message": self.message, "source": self.source, "line": self.line,
        }


@dataclass
class Result:
    classes: list[dict[str, Any]] = field(default_factory=list)
    diagnostics: list[Diagnostic] = field(default_factory=list)


class UnsupportedNode(Exception):
    pass


def node_text(node: Any, source: bytes) -> str:
    return source[node.start_byte:node.end_byte].decode("utf-8", errors="replace")


def line_of(node: Any) -> int:
    return int(node.start_point[0]) + 1


def child(node: Any, name: str) -> Any | None:
    return node.child_by_field_name(name)


def named(node: Any) -> list[Any]:
    return list(node.named_children)


def walk(node: Any):
    yield node
    for item in node.children:
        yield from walk(item)


def operator_between(node: Any, left: Any, right: Any, source: bytes) -> str:
    for item in node.children:
        if (not item.is_named and item.start_byte >= left.end_byte
                and item.end_byte <= right.start_byte):
            value = node_text(item, source).strip()
            if value:
                return value
    between = source[left.end_byte:right.start_byte].decode("utf-8", errors="replace")
    match = re.search(r"(>>>|>>|<<|&&|\|\||==|!=|<=|>=|\+=|-=|\*=|/=|%=|[+\-*/%<>=&|^])", between)
    return match.group(1) if match else ""


class JavaConverter:
    def __init__(self, source: bytes, source_name: str, mappings: dict[str, Any],
                 class_methods: set[str]):
        self.source = source
        self.source_name = source_name
        self.mappings = mappings
        self.class_methods = class_methods
        self.diagnostics: list[Diagnostic] = []

    def error(self, node: Any, message: str, code: str = "unsupported_java") -> None:
        self.diagnostics.append(Diagnostic(
            "warning", code, message, self.source_name, line_of(node)
        ))

    def fail(self, node: Any, message: str) -> None:
        self.error(node, message)
        raise UnsupportedNode(message)

    def expression(self, node: Any) -> dict[str, Any]:
        if node is None:
            raise UnsupportedNode("Missing expression")
        kind = node.type
        raw = node_text(node, self.source).strip()

        if kind in {"identifier", "type_identifier"}:
            return {"kind": "name", "name": raw}
        if kind == "this":
            return {"kind": "name", "name": "self"}
        if kind in {"decimal_integer_literal", "hex_integer_literal",
                    "octal_integer_literal", "binary_integer_literal",
                    "decimal_floating_point_literal", "hex_floating_point_literal"}:
            value = raw.replace("_", "")
            value = re.sub(r"(?i)[fdl]$", "", value)
            return {"kind": "number", "value": value}
        if kind in {"true", "false"}:
            return {"kind": "boolean", "value": kind == "true"}
        if kind == "null_literal":
            return {"kind": "nil"}
        if kind == "string_literal":
            return {"kind": "string", "value": raw}
        if kind == "character_literal":
            return {"kind": "character", "value": raw}
        if kind == "parenthesized_expression":
            items = named(node)
            if len(items) != 1:
                self.fail(node, "Malformed parenthesized expression")
            return self.expression(items[0])
        if kind == "cast_expression":
            value = child(node, "value")
            cast_type = child(node, "type")
            type_name = node_text(cast_type, self.source) if cast_type else ""
            if type_name not in PRIMITIVE_C_TYPES or type_name in {"void", "boolean", "char"}:
                self.fail(node, f"Non-numeric Java cast is not portable: {type_name}")
            return self.expression(value)
        if kind == "binary_expression":
            left, right = child(node, "left"), child(node, "right")
            if left is None or right is None:
                self.fail(node, "Malformed binary expression")
            op = operator_between(node, left, right, self.source)
            if op not in {"+", "-", "*", "/", "%", "<", ">", "<=", ">=", "==", "!=", "&&", "||"}:
                self.fail(node, f"Binary operator {op!r} is not supported by both backends")
            return {"kind": "binary", "op": op,
                    "left": self.expression(left), "right": self.expression(right)}
        if kind == "unary_expression":
            operand = child(node, "operand")
            if operand is None:
                items = named(node)
                operand = items[-1] if items else None
            op = next((node_text(c, self.source).strip() for c in node.children
                       if not c.is_named and node_text(c, self.source).strip()), "")
            if op not in {"!", "-", "+"}:
                self.fail(node, f"Unary operator {op!r} is unsupported")
            return {"kind": "unary", "op": op, "value": self.expression(operand)}
        if kind == "field_access":
            obj, member = child(node, "object"), child(node, "field")
            if obj is None or member is None:
                self.fail(node, "Malformed field access")
            object_name = node_text(obj, self.source).replace(" ", "")
            member_name = node_text(member, self.source)
            mapped = self.mappings.get("static_fields", {}).get(f"{object_name}.{member_name}")
            if mapped:
                return {"kind": "mapped_name", "lua": mapped["lua"], "c": mapped["c"]}
            return {"kind": "field", "object": self.expression(obj), "field": member_name}
        if kind == "method_invocation":
            obj, name, args_node = child(node, "object"), child(node, "name"), child(node, "arguments")
            if name is None:
                self.fail(node, "Method invocation has no name")
            method_name = node_text(name, self.source)
            args = [self.expression(n) for n in named(args_node)] if args_node else []
            object_name = node_text(obj, self.source).replace(" ", "") if obj else ""
            map_key = f"{object_name}.{method_name}" if object_name else method_name
            mapped = self.mappings.get("static_methods", {}).get(map_key)
            if mapped:
                return {"kind": "call", "lua": mapped["lua"], "c": mapped["c"], "args": args}
            if object_name == "this" and method_name in self.class_methods:
                return {"kind": "call", "lua": f"self:{method_name}",
                        "c": "", "args": args, "instance_call": True}
            self.fail(node, f"Unmapped Java method call: {map_key or method_name}")
        if kind == "assignment_expression":
            left, right = child(node, "left"), child(node, "right")
            if left is None or right is None:
                self.fail(node, "Malformed assignment expression")
            op = operator_between(node, left, right, self.source)
            if op not in {"=", "+=", "-=", "*=", "/=", "%="}:
                self.fail(node, f"Assignment operator {op!r} is unsupported")
            return {"kind": "assign", "op": op,
                    "left": self.expression(left), "right": self.expression(right)}
        if kind == "update_expression":
            self.fail(node, "Increment/decrement is not yet translated; use x = x +/- 1")
        self.fail(node, f"Unsupported Java expression: {kind} ({raw[:80]})")
        raise UnsupportedNode(kind)

    def statement(self, node: Any) -> list[dict[str, Any]]:
        kind = node.type
        if kind == "comment":
            return []
        if kind == "block":
            output: list[dict[str, Any]] = []
            for item in named(node):
                output.extend(self.statement(item))
            return output
        if kind == "empty_statement":
            return []
        if kind == "return_statement":
            items = [n for n in named(node) if n.type != "comment"]
            return [{"kind": "return", "value": self.expression(items[0]) if items else None}]
        if kind == "if_statement":
            condition = child(node, "condition")
            consequence = child(node, "consequence")
            alternative = child(node, "alternative")
            if alternative is not None and alternative.type == "else_clause":
                alt_items = [n for n in named(alternative) if n.type != "comment"]
                alternative = alt_items[-1] if alt_items else None
            return [{
                "kind": "if", "condition": self.expression(condition),
                "then": self.statement(consequence) if consequence else [],
                "else": self.statement(alternative) if alternative else [],
            }]
        if kind == "while_statement":
            condition, body = child(node, "condition"), child(node, "body")
            return [{"kind": "while", "condition": self.expression(condition),
                     "body": self.statement(body) if body else []}]
        if kind == "local_variable_declaration":
            type_node = child(node, "type")
            type_name = node_text(type_node, self.source).replace(" ", "") if type_node else ""
            declarations = [n for n in named(node) if n.type == "variable_declarator"]
            if not declarations:
                self.fail_stmt(node, "Local declaration has no variable")
            output = []
            for declaration in declarations:
                name_node = child(declaration, "name")
                value_node = child(declaration, "value")
                if name_node is None:
                    self.fail_stmt(node, "Local declaration has no variable name")
                output.append({
                    "kind": "local", "type": type_name,
                    "name": node_text(name_node, self.source),
                    "value": self.expression(value_node) if value_node else None,
                })
            return output
        if kind == "expression_statement":
            items = [n for n in named(node) if n.type != "comment"]
            if not items:
                return []
            expr = self.expression(items[0])
            if expr["kind"] == "assign":
                return [expr]
            return [{"kind": "expression", "value": expr}]
        if kind == "break_statement":
            return [{"kind": "break"}]
        if kind == "continue_statement":
            return [{"kind": "continue"}]
        self.fail_stmt(node, f"Unsupported Java statement: {kind}")

    def fail_stmt(self, node: Any, message: str) -> None:
        self.error(node, message)
        raise UnsupportedNode(message)


def sanitize_identifier(name: str, target: str = "lua") -> str:
    value = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not value or value[0].isdigit():
        value = "j_" + value
    if target == "lua" and value in LUA_RESERVED:
        value = "j_" + value
    return value


def emit_expression(expr: dict[str, Any], target: str) -> str:
    kind = expr["kind"]
    if kind == "name":
        return sanitize_identifier(expr["name"], target)
    if kind == "number":
        return expr["value"]
    if kind == "boolean":
        return "true" if expr["value"] else "false"
    if kind == "nil":
        return "nil" if target == "lua" else "NULL"
    if kind == "string":
        return expr["value"]
    if kind == "character":
        return expr["value"]
    if kind == "mapped_name":
        return expr[target]
    if kind == "field":
        obj = emit_expression(expr["object"], target)
        field_name = sanitize_identifier(expr["field"], target)
        return f"{obj}.{field_name}"
    if kind == "binary":
        op = expr["op"]
        if target == "lua":
            op = {"!=": "~=", "&&": "and", "||": "or"}.get(op, op)
        return f"({emit_expression(expr['left'], target)} {op} {emit_expression(expr['right'], target)})"
    if kind == "unary":
        op = expr["op"]
        if target == "lua" and op == "!":
            op = "not "
        return f"({op}{emit_expression(expr['value'], target)})"
    if kind == "call":
        args = [emit_expression(a, target) for a in expr["args"]]
        callee = expr[target]
        if callee == "@clamp":
            if len(args) != 3:
                raise ValueError("clamp mapping expects (value, min, max)")
            return (f"math.max({args[1]}, math.min({args[2]}, {args[0]}))"
                    if target == "lua" else f"fmax({args[1]}, fmin({args[2]}, {args[0]}))")
        if callee == "@lerp":
            if len(args) != 3:
                raise ValueError("lerp mapping expects (delta, start, end)")
            return f"({args[1]} + ({args[0]} * ({args[2]} - {args[1]})))"
        return f"{callee}({', '.join(args)})"
    raise ValueError(f"Unknown IR expression kind: {kind}")


def emit_statements(statements: list[dict[str, Any]], target: str, indent: int = 1) -> list[str]:
    pad = "    " * indent
    output: list[str] = []
    for stmt in statements:
        kind = stmt["kind"]
        if kind == "local":
            name = sanitize_identifier(stmt["name"], target)
            value = stmt["value"]
            if target == "lua":
                output.append(f"{pad}local {name}" + (f" = {emit_expression(value, target)}" if value else " = nil"))
            else:
                c_type = PRIMITIVE_C_TYPES.get(stmt["type"])
                if c_type is None:
                    raise ValueError(f"Local type is not supported by C backend: {stmt['type']}")
                output.append(f"{pad}{c_type} {name}" + (f" = {emit_expression(value, target)}" if value else "") + ";")
        elif kind == "assign":
            lhs, rhs = emit_expression(stmt["left"], target), emit_expression(stmt["right"], target)
            op = stmt["op"]
            if target == "lua" and op != "=":
                output.append(f"{pad}{lhs} = {lhs} {op[0]} {rhs}")
            else:
                output.append(f"{pad}{lhs} {op} {rhs}" + ("" if target == "lua" else ";"))
        elif kind == "expression":
            value = emit_expression(stmt["value"], target)
            output.append(f"{pad}{value}" + ("" if target == "lua" else ";"))
        elif kind == "return":
            value = stmt["value"]
            output.append(f"{pad}return" + (f" {emit_expression(value, target)}" if value else "") + ("" if target == "lua" else ";"))
        elif kind in {"break", "continue"}:
            output.append(f"{pad}{kind}" + ("" if target == "lua" else ";"))
        elif kind == "if":
            condition = emit_expression(stmt["condition"], target)
            if target == "lua":
                output.append(f"{pad}if {condition} then")
                output.extend(emit_statements(stmt["then"], target, indent + 1))
                if stmt["else"]:
                    output.append(f"{pad}else")
                    output.extend(emit_statements(stmt["else"], target, indent + 1))
                output.append(f"{pad}end")
            else:
                output.append(f"{pad}if ({condition}) {{")
                output.extend(emit_statements(stmt["then"], target, indent + 1))
                if stmt["else"]:
                    output.append(f"{pad}}} else {{")
                    output.extend(emit_statements(stmt["else"], target, indent + 1))
                output.append(f"{pad}}}")
        elif kind == "while":
            condition = emit_expression(stmt["condition"], target)
            if target == "lua":
                output.append(f"{pad}while {condition} do")
                output.extend(emit_statements(stmt["body"], target, indent + 1))
                output.append(f"{pad}end")
            else:
                output.append(f"{pad}while ({condition}) {{")
                output.extend(emit_statements(stmt["body"], target, indent + 1))
                output.append(f"{pad}}}")
        else:
            raise ValueError(f"Unknown IR statement kind: {kind}")
    return output


def parse_classes(source: bytes, source_name: str, mappings: dict[str, Any]) -> Result:
    result = Result()
    tree = make_parser().parse(source)
    if tree.root_node.has_error:
        first_error = next((n for n in walk(tree.root_node) if n.type == "ERROR" or n.is_missing), tree.root_node)
        result.diagnostics.append(Diagnostic(
            "error", "java_parse_error",
            "Tree-sitter found Java syntax errors; no code from this source file was emitted.",
            source_name, line_of(first_error)
        ))
        return result

    package = ""
    imports: list[str] = []
    for top in named(tree.root_node):
        if top.type == "package_declaration":
            package = node_text(top, source).replace("package", "", 1).replace(";", "").strip()
        elif top.type == "import_declaration":
            imports.append(node_text(top, source).replace("import", "", 1).replace(";", "").strip())

    class_nodes = [n for n in named(tree.root_node)
                   if n.type in {"class_declaration", "record_declaration"}]
    for class_node in class_nodes:
        name_node, body_node = child(class_node, "name"), child(class_node, "body")
        if name_node is None or body_node is None:
            result.diagnostics.append(Diagnostic(
                "warning", "class_shape_unsupported", "Class declaration shape is not supported.",
                source_name, line_of(class_node)
            ))
            continue
        class_name = node_text(name_node, source)
        fqcn = f"{package}.{class_name}" if package else class_name
        methods_nodes = [n for n in named(body_node) if n.type == "method_declaration"]
        method_names = {
            node_text(child(n, "name"), source)
            for n in methods_nodes if child(n, "name") is not None
        }
        methods: list[dict[str, Any]] = []
        for method_node in methods_nodes:
            name, return_type = child(method_node, "name"), child(method_node, "type")
            params_node, body = child(method_node, "parameters"), child(method_node, "body")
            if name is None or body is None:
                result.diagnostics.append(Diagnostic(
                    "warning", "abstract_method_skipped",
                    "Abstract/native method has no body and cannot be transpiled.",
                    source_name, line_of(method_node)
                ))
                continue
            modifiers_node = next((n for n in named(method_node) if n.type == "modifiers"), None)
            modifiers = node_text(modifiers_node, source) if modifiers_node else ""
            params = []
            if params_node:
                for param in named(params_node):
                    if param.type not in {"formal_parameter", "spread_parameter"}:
                        continue
                    param_name, param_type = child(param, "name"), child(param, "type")
                    if param_name is None or param_type is None:
                        result.diagnostics.append(Diagnostic(
                            "warning", "parameter_shape_unsupported", "Parameter form is not supported.",
                            source_name, line_of(param)
                        ))
                        continue
                    params.append({
                        "name": node_text(param_name, source),
                        "type": node_text(param_type, source).replace(" ", ""),
                    })
            converter = JavaConverter(source, source_name, mappings, method_names)
            try:
                body_ir = converter.statement(body)
                supported = True
            except UnsupportedNode:
                body_ir, supported = [], False
            result.diagnostics.extend(converter.diagnostics)
            methods.append({
                "name": node_text(name, source),
                "return_type": node_text(return_type, source).replace(" ", "") if return_type else "void",
                "parameters": params,
                "static": "static" in modifiers.split(),
                "modifiers": modifiers.split(),
                "line": line_of(method_node),
                "supported": supported,
                "body": body_ir,
            })
        field_count = sum(1 for n in named(body_node) if n.type == "field_declaration")
        if field_count:
            result.diagnostics.append(Diagnostic(
                "warning", "class_fields_skipped",
                f"{field_count} Java field declaration(s) were found. Object/static state is not emitted yet.",
                source_name, line_of(class_node)
            ))
        result.classes.append({
            "name": class_name, "qualified_name": fqcn, "package": package,
            "source": source_name, "imports": imports, "methods": methods,
            "field_declarations_skipped": field_count,
        })
    return result


def load_sources(input_path: Path) -> list[tuple[str, bytes]]:
    if not input_path.exists():
        raise FileNotFoundError(f"Input path does not exist: {input_path}")
    if input_path.is_dir():
        excluded = {".git", ".gradle", "build", "target", "out", "node_modules"}
        files = [p for p in input_path.rglob("*.java")
                 if not any(part in excluded for part in p.parts)]
        return [(p.relative_to(input_path).as_posix(), p.read_bytes()) for p in sorted(files)]
    if input_path.suffix.lower() == ".java":
        return [(input_path.name, input_path.read_bytes())]
    if input_path.suffix.lower() in {".zip", ".jar"}:
        with zipfile.ZipFile(input_path) as archive:
            java_entries = [n for n in archive.namelist()
                            if n.lower().endswith(".java") and not n.startswith("__MACOSX/")]
            if not java_entries:
                raise ValueError(
                    "Archive contains no .java sources. A normal Minecraft client JAR "
                    "contains .class bytecode, not source; provide a mapped source JAR "
                    "or decompiled Java sources."
                )
            return [(name, archive.read(name)) for name in sorted(java_entries)]
    raise ValueError("Input must be a .java file, a source directory, or a ZIP/source-JAR containing .java files.")


def load_mappings(custom_path: Path | None) -> dict[str, Any]:
    default_path = Path(__file__).with_name("mappings") / "sm64coopdx.json"
    mappings = json.loads(default_path.read_text(encoding="utf-8"))
    if custom_path:
        custom = json.loads(custom_path.read_text(encoding="utf-8"))
        for section in ("static_methods", "static_fields"):
            mappings.setdefault(section, {}).update(custom.get(section, {}))
    return mappings


def lua_backend(class_ir: dict[str, Any]) -> tuple[str, int, list[str]]:
    lines = [
        "-- Generated by mc2sm64.py. Review before loading in SM64CoopDX.",
        f"-- Source class: {class_ir['qualified_name']}", "local M = {}", "",
    ]
    generated, skipped = 0, []
    for method in class_ir["methods"]:
        if not method["supported"]:
            skipped.append(method["name"])
            continue
        params = [sanitize_identifier(p["name"]) for p in method["parameters"]]
        if not method["static"]:
            params.insert(0, "self")
        lines.append(f"M[{json.dumps(method['name'])}] = function({', '.join(params)})")
        try:
            lines.extend(emit_statements(method["body"], "lua", 1))
        except ValueError as exc:
            skipped.append(method["name"])
            lines.extend([f"    -- Not emitted: {exc}", "end"])
            continue
        lines.extend(["end", ""])
        generated += 1
    lines.extend(["return M", ""])
    return "\n".join(lines), generated, skipped


def c_backend(class_ir: dict[str, Any], file_base: str) -> tuple[str, str, int, list[str]]:
    name = sanitize_identifier(class_ir["name"], "c")
    file_base = sanitize_identifier(file_base, "c")
    guard = f"MC2SM64_{file_base.upper()}_H"
    prototypes, definitions, skipped, generated = [], [], [], 0
    for method in class_ir["methods"]:
        if not method["supported"]:
            skipped.append(method["name"])
            continue
        if not method["static"]:
            skipped.append(method["name"] + " (instance method needs a generated state struct)")
            continue
        return_type = PRIMITIVE_C_TYPES.get(method["return_type"])
        param_types = [PRIMITIVE_C_TYPES.get(p["type"]) for p in method["parameters"]]
        if return_type is None or any(t is None for t in param_types):
            skipped.append(method["name"] + " (non-primitive type)")
            continue
        function_name = sanitize_identifier(name + "_" + method["name"], "c")
        params = [f"{ptype} {sanitize_identifier(p['name'], 'c')}"
                  for ptype, p in zip(param_types, method["parameters"])]
        signature = f"{return_type} {function_name}({', '.join(params) if params else 'void'})"
        try:
            body_lines = emit_statements(method["body"], "c", 1)
        except ValueError as exc:
            skipped.append(method["name"] + f" ({exc})")
            continue
        prototypes.append(signature + ";")
        definitions.extend([signature + " {", *body_lines, "}", ""])
        generated += 1
    header = "\n".join([
        f"#ifndef {guard}", f"#define {guard}", "#include <stdbool.h>",
        "#include <stdint.h>", "", *prototypes, "", "#endif", "",
    ])
    source = "\n".join([
        f'#include "{file_base}.h"', "#include <math.h>", "#include <stdbool.h>",
        "#include <stdint.h>", "", "#ifndef M_PI",
        "#define M_PI 3.14159265358979323846", "#endif", "", *definitions,
    ])
    return header, source, generated, skipped


def transpile(input_path: Path, output_path: Path, target: str,
              custom_mapping: Path | None = None) -> dict[str, Any]:
    sources = load_sources(input_path)
    if not sources:
        raise ValueError("No .java files found in the input.")
    mappings = load_mappings(custom_mapping)
    output_path.mkdir(parents=True, exist_ok=True)
    ir_dir = output_path / "ir"
    ir_dir.mkdir(exist_ok=True)
    generated = {"lua": 0, "c": 0}
    diagnostics: list[Diagnostic] = []
    class_count = method_count = 0
    emitted_files: list[str] = []
    unsupported_methods: list[str] = []

    for source_name, source in sources:
        parsed = parse_classes(source, source_name, mappings)
        diagnostics.extend(parsed.diagnostics)
        for class_ir in parsed.classes:
            class_count += 1
            method_count += len(class_ir["methods"])
            slug = re.sub(r"[^A-Za-z0-9_.-]", "_", class_ir["qualified_name"])
            (ir_dir / f"{slug}.json").write_text(
                json.dumps(class_ir, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            if target in {"lua", "both"}:
                text, count, skipped = lua_backend(class_ir)
                if count:
                    lua_dir = output_path / "lua"
                    lua_dir.mkdir(exist_ok=True)
                    path = lua_dir / f"{slug.replace('.', '_')}.lua"
                    path.write_text(text, encoding="utf-8")
                    emitted_files.append(path.relative_to(output_path).as_posix())
                generated["lua"] += count
                unsupported_methods.extend(f"{class_ir['qualified_name']}.{x}" for x in skipped)
            if target in {"c", "both"}:
                header, source_text, count, skipped = c_backend(class_ir, slug.replace('.', '_'))
                if count:
                    c_dir = output_path / "c"
                    c_dir.mkdir(exist_ok=True)
                    base = slug.replace(".", "_")
                    h_path, c_path = c_dir / f"{base}.h", c_dir / f"{base}.c"
                    h_path.write_text(header, encoding="utf-8")
                    c_path.write_text(source_text, encoding="utf-8")
                    emitted_files.extend([
                        h_path.relative_to(output_path).as_posix(),
                        c_path.relative_to(output_path).as_posix(),
                    ])
                generated["c"] += count
                unsupported_methods.extend(f"{class_ir['qualified_name']}.{x}" for x in skipped)

    report = {
        "tool": "mc2sm64", "tool_version": "0.1.0-alpha",
        "input": str(input_path), "source_files": len(sources),
        "classes": class_count, "methods_seen": method_count,
        "generated_methods": generated,
        "unsupported_methods": sorted(set(unsupported_methods)),
        "emitted_files": sorted(set(emitted_files)),
        "diagnostics": [d.as_dict() for d in diagnostics],
        "limitations": [
            "Only a conservative Java subset is translated.",
            "Class fields, object construction, inheritance, generics, arrays, lambdas, exceptions, switch, for-loops, and arbitrary Minecraft API calls are not emitted.",
            "Lua output is a pure module; hook registration and Minecraft-to-SM64 gameplay mappings must be added explicitly.",
            "C output emits static primitive-only helpers; integrating generated C requires rebuilding SM64CoopDX.",
            "A binary Minecraft JAR is not Java source and is not decompiled by this tool.",
        ],
    }
    (output_path / "diagnostics.json").write_text(
        json.dumps(report["diagnostics"], indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (output_path / "manifest.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return report


def main() -> int:
    cli = argparse.ArgumentParser(
        description="Conservatively transpile a portable Java subset into SM64CoopDX Lua and/or C."
    )
    cli.add_argument("--input", required=True, type=Path,
                     help="Java source file, source directory, or ZIP/source-JAR containing .java files.")
    cli.add_argument("--out", required=True, type=Path, help="Output directory.")
    cli.add_argument("--target", choices=("lua", "c", "both"), default="both")
    cli.add_argument("--mapping", type=Path, help="Optional JSON mapping file.")
    cli.add_argument("--strict", action="store_true",
                     help="Return exit code 2 if any method or construct could not be emitted.")
    args = cli.parse_args()
    try:
        report = transpile(args.input, args.out, args.target, args.mapping)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"mc2sm64: error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({
        "status": "completed_with_diagnostics" if report["diagnostics"] or report["unsupported_methods"] else "completed",
        "source_files": report["source_files"], "classes": report["classes"],
        "methods_seen": report["methods_seen"], "generated_methods": report["generated_methods"],
        "unsupported_methods": len(report["unsupported_methods"]), "output": str(args.out),
    }, indent=2))
    if args.strict and (report["diagnostics"] or report["unsupported_methods"]):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
