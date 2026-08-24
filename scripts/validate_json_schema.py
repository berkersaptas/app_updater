#!/usr/bin/env python3
"""Minimal, dependency-free JSON Schema validator.

Supports only the subset of JSON Schema draft 2020-12 used by ota_core schemas:
type, const, enum, pattern, minLength, minimum, maximum, required, properties,
and additionalProperties: false. No external dependencies.
"""
import json
import re
import sys

_TYPE_MAP = {
    "object": dict,
    "string": str,
    "integer": int,
    "number": (int, float),
    "array": list,
    "boolean": bool,
}


def validate(instance, schema, path="$"):
    if "const" in schema and instance != schema["const"]:
        raise ValueError(f"{path}: expected const {schema['const']!r}, got {instance!r}")

    if "type" in schema:
        expected = _TYPE_MAP[schema["type"]]
        if schema["type"] == "integer" and isinstance(instance, bool):
            raise ValueError(f"{path}: expected integer, got bool")
        if not isinstance(instance, expected):
            raise ValueError(f"{path}: expected type {schema['type']}, got {type(instance).__name__}")

    if "enum" in schema and instance not in schema["enum"]:
        raise ValueError(f"{path}: {instance!r} not in enum {schema['enum']}")

    if isinstance(instance, str):
        if "pattern" in schema and not re.match(schema["pattern"], instance):
            raise ValueError(f"{path}: {instance!r} does not match pattern {schema['pattern']!r}")
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise ValueError(f"{path}: length {len(instance)} < minLength {schema['minLength']}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValueError(f"{path}: {instance} < minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise ValueError(f"{path}: {instance} > maximum {schema['maximum']}")

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                raise ValueError(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = set(instance) - set(properties)
            if unknown:
                raise ValueError(f"{path}: unexpected properties {sorted(unknown)}")
        for key, value in instance.items():
            if key in properties:
                validate(value, properties[key], f"{path}.{key}")

    return instance


def main(argv):
    if len(argv) != 3:
        print(f"Usage: {argv[0]} <schema.json> <instance.json>", file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        schema = json.load(f)
    with open(argv[2], encoding="utf-8") as f:
        instance = json.load(f)
    try:
        validate(instance, schema)
    except ValueError as exc:
        print(f"Schema validation failed: {exc}", file=sys.stderr)
        return 1
    print(f"{argv[2]} is valid against {argv[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
