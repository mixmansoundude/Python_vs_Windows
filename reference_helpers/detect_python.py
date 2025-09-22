import os, re, sys

CD = os.getcwd()
rt_path = os.path.join(CD, 'runtime.txt')
pp_path = os.path.join(CD, 'pyproject.toml')

def rt_spec(text):
    match = re.search(r'(?:python[-=])?\s*([0-9]+(?:\.[0-9]+){0,2})', text)
    if not match:
        return ''
    value = match.group(1)
    parts = value.split('.')
    major_minor = '.'.join(parts[:2])
    return f'python={major_minor}'

def pep440_to_conda(specs):
    out = []
    for raw in re.split(r'\s*,\s*', specs.strip()):
        if not raw:
            continue
        match = re.match(r'(>=|>|<=|<|==|~=)\s*([0-9]+(?:\.[0-9]+){0,2})\s*$', raw)
        if not match:
            continue
        op, ver = match.group(1), match.group(2)
        if op == '~=':
            parts = [int(x) for x in ver.split('.')]
            if len(parts) == 1:
                upper = str(parts[0] + 1)
            else:
                upper = f"{parts[0]}.{parts[1] + 1}"
            out.append(f'python>={ver},<{upper}')
        else:
            out.append(f'python{op}{ver}')
    return ','.join([item for item in out if item])

def main():
    if os.path.exists(rt_path):
        with open(rt_path, 'r', encoding='utf-8', errors='ignore') as handle:
            spec = rt_spec(handle.read())
            if spec:
                print(spec)
                return
    if os.path.exists(pp_path):
        with open(pp_path, 'r', encoding='utf-8', errors='ignore') as handle:
            text = handle.read()
        match = re.search(r'requires-python\s*=\s*["\']([^"\']+)["\']', text)
        if match:
            converted = pep440_to_conda(match.group(1))
            print(converted)
            return
    print('')

if __name__ == '__main__':
    main()
