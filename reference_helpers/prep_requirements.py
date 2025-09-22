import os, re, sys

INP = sys.argv[1] if len(sys.argv) > 1 else 'requirements.txt'
OUT_CONDA = '~reqs_conda.txt'
OUT_PIP = '~reqs_pip.txt'

def norm(line):
    return line.strip()

def split_marker(text):
    return text.split(';')[0].strip()

def strip_extras(name):
    return re.sub(r"\[.*?\]", '', name)

def bump_for_compatible(value):
    parts = [int(x) for x in value.split('.')]
    if len(parts) == 1:
        return str(parts[0] + 1)
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1] + 1}"
    return value

def to_conda(line):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return []
    if section.startswith('-e ') or section.startswith('--editable') or section.startswith('git+') or '://' in section:
        return []
    match = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*(.*)$", section)
    if not match:
        return []
    name, rest = match.group(1), match.group(2).strip()
    name = strip_extras(name)
    if not rest:
        return [name]
    rest = rest.replace(' ', '')
    match_compat = re.match(r"^~=\s*([0-9]+(?:\.[0-9]+){0,2})$", rest)
    if match_compat:
        base = match_compat.group(1)
        upper = bump_for_compatible(base)
        return [f"{name} >={base},<{upper}"]
    segments = [part for part in rest.split(',') if part]
    ops = []
    for part in segments:
        m = re.match(r"^(>=|<=|==|!=|>|<)\s*([0-9]+(?:\.[0-9]+){0,5})$", part)
        if m:
            ops.append(f"{m.group(1)}{m.group(2)}")
    return [f"{name} " + ','.join(ops)] if ops else [name]

def to_pip(line):
    section = split_marker(line)
    if not section or section.startswith('#'):
        return None
    match = re.match(r"^\s*([A-Za-z0-9_.-]+)(.*)$", section)
    if not match:
        return section.strip()
    name, rest = match.group(1), match.group(2)
    name = strip_extras(name)
    return (name + rest).strip()

def main():
    have_file = os.path.exists(INP) and os.path.getsize(INP) > 0
    lines = []
    if have_file:
        with open(INP, 'r', encoding='utf-8', errors='ignore') as handle:
            lines = [norm(item) for item in handle if norm(item)]
    conda_specs = []
    pip_specs = []
    for line in lines:
        conda_specs.extend(to_conda(line))
        pip_entry = to_pip(line)
        if pip_entry:
            pip_specs.append(pip_entry)
    names_lower = [re.split(r"[<>=!~,\s]", value, 1)[0].strip().lower() for value in pip_specs]
    if 'pandas' in names_lower and 'openpyxl' not in names_lower:
        pip_specs.append('openpyxl')
        conda_specs.append('openpyxl')
    with open(OUT_CONDA, 'w', encoding='ascii') as handle:
        for item in conda_specs:
            if item:
                handle.write(item + '\n')
    with open(OUT_PIP, 'w', encoding='ascii') as handle:
        for item in pip_specs:
            if item:
                handle.write(item + '\n')
    sys.stdout.write('OK\n')

if __name__ == '__main__':
    main()
