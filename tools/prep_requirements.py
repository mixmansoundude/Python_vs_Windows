OP_ORDER = ("==", "!=", ">=", ">", "<=", "<")
OP_RANK = {op: idx for idx, op in enumerate(OP_ORDER)}

import os
import re
import sys
from collections import OrderedDict

INP = sys.argv[1] if len(sys.argv) > 1 else "requirements.txt"
OUT_CONDA = "~reqs_conda.txt"
OUT_PIP = "~reqs_pip.txt"
SPEC_PATTERN = re.compile(r"(~=|==|!=|>=|>|<=|<)\s*([^\s,;]+)\s*$")
NAME_PATTERN = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*(.*)$")

def split_marker(text: str) -> str:
    return text.split(";")[0].strip()

def _version_key(text: str):
    parts = []
    for chunk in text.split('.'):
        try:
            parts.append(int(chunk))
        except ValueError:
            parts.append(0)
    return tuple(parts)

def _bump_compatible(value: str) -> str:
    pieces = value.split('.')
    if not pieces or not pieces[0].isdigit():
        return value
    major = int(pieces[0])
    if len(pieces) >= 3 and pieces[1].isdigit():
        return f"{major}.{int(pieces[1]) + 1}"
    if len(pieces) >= 2:
        return f"{major + 1}.0"
    return str(major + 1)

def _expand_fragment(fragment: str):
    if not fragment:
        return []
    value = fragment.strip()
    if not value:
        return []
    match = SPEC_PATTERN.fullmatch(value)
    if not match:
        return []
    op, ver = match.groups()
    ver = ver.strip()
    if not ver:
        return []
    if op == "~=":
        upper = _bump_compatible(ver)
        return [f">={ver}", f"<{upper}"]
    return [f"{op}{ver}"]

def canonical_ops(specs) -> list:
    bucket = OrderedDict()
    for raw in specs:
        for normalized in _expand_fragment(raw):
            bucket[normalized] = None
    ordered = list(bucket.keys())
    ordered.sort(key=_spec_sort_key)
    return _enforce_bounds_order(ordered)

def _spec_sort_key(value: str):
    for op in OP_ORDER:
        if value.startswith(op):
            ver = value[len(op):]
            return OP_RANK[op], _version_key(ver), ver
    return len(OP_ORDER), _version_key(value), value

def _enforce_bounds_order(items: list) -> list:
    ops = list(items)
    lower_index = next((idx for idx, text in enumerate(ops) if text.startswith(">=")), None)
    if lower_index is None:
        return ops
    for upper_op in ("<=", "<"):
        upper_index = next((idx for idx, text in enumerate(ops) if text.startswith(upper_op)), None)
        if upper_index is not None and upper_index < lower_index:
            value = ops.pop(lower_index)
            ops.insert(upper_index, value)
            lower_index = upper_index
    return ops

def format_line(name: str, specs) -> list:
    ops = canonical_ops(specs)
    return [f"{name} " + ",".join(ops)] if ops else [name]

def to_conda(line: str):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return []
    match = NAME_PATTERN.match(section)
    if not match:
        return []
    name, rest = match.groups()
    rest = re.sub(r"\[.*?\]", "", rest)
    specs = [chunk.strip() for chunk in rest.split(',') if chunk.strip()]
    return format_line(name, specs)

def to_pip(line: str):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return None
    match = NAME_PATTERN.match(section)
    if not match:
        return section.strip()
    name, rest = match.groups()
    return (name + rest).strip()

def main():
    have_file = os.path.exists(INP) and os.path.getsize(INP) > 0
    lines = []
    if have_file:
        with open(INP, 'r', encoding='utf-8', errors='ignore') as handle:
            lines = [item.strip() for item in handle if item.strip()]
    conda_specs = []
    pip_specs = []
    for line in lines:
        conda_specs.extend(to_conda(line))
        pip_entry = to_pip(line)
        if pip_entry:
            pip_specs.append(pip_entry)
    names_lower = [re.split(r"[<>=!~,\s\[]", value, maxsplit=1)[0].strip().lower() for value in pip_specs]
    n0 = len(pip_specs)
    if os.environ.get('HP_DISABLE_HEURISTICS') != '1':
        if 'pandas' in names_lower and 'openpyxl' not in names_lower:
            pip_specs.append('openpyxl')
            conda_specs.extend(format_line('openpyxl', []))
            sys.stderr.write('[HEURISTIC] pandas->openpyxl\n')
        if 'pandas' in names_lower and 'xlsxwriter' not in names_lower:
            pip_specs.append('xlsxwriter')
            conda_specs.extend(format_line('xlsxwriter', []))
            sys.stderr.write('[HEURISTIC] pandas->xlsxwriter\n')
        if 'requests' in names_lower and 'certifi' not in names_lower:
            pip_specs.append('certifi')
            conda_specs.extend(format_line('certifi', []))
            sys.stderr.write('[HEURISTIC] requests->certifi\n')
        if 'sqlalchemy' in names_lower and 'pymysql' not in names_lower:
            pip_specs.append('pymysql')
            conda_specs.extend(format_line('pymysql', []))
            sys.stderr.write('[HEURISTIC] sqlalchemy->pymysql\n')
        if 'matplotlib' in names_lower and 'tk' not in names_lower:
            conda_specs.extend(format_line('tk', []))
            sys.stderr.write('[HEURISTIC] matplotlib->tk\n')
        if ('cryptography' in names_lower or 'pycryptodome' in names_lower) and 'cffi' not in names_lower:
            pip_specs.append('cffi')
            conda_specs.extend(format_line('cffi', []))
            sys.stderr.write('[HEURISTIC] crypto->cffi\n')
    with open(OUT_CONDA, 'w', encoding='ascii') as handle:
        for item in conda_specs:
            if item:
                handle.write(item + '\n')
    with open(OUT_PIP, 'w', encoding='ascii') as handle:
        for item in pip_specs:
            if item:
                handle.write(item + '\n')
    added = pip_specs[n0:]
    if added:
        with open(INP, 'a', encoding='utf-8') as handle:
            handle.write('\n' + '\n'.join(added) + '\n')
    sys.stdout.write('OK\n')

if __name__ == '__main__':
    main()
