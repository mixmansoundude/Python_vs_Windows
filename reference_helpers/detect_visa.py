import os, re, sys

ROOT = os.getcwd()
PATTERNS = [
    r"(?m)^\s*(?:from\s+pyvis|import\s+pyvis)",
    r"(?m)^\s*import\s+vis",
]

def needs_visa():
    for current, dirs, files in os.walk(ROOT):
        dirs[:] = [item for item in dirs if not item.startswith(('~', '.'))]
        for name in files:
            if not name.endswith('.py') or name.startswith('~'):
                continue
            path = os.path.join(current, name)
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as handle:
                    text = handle.read()
            except OSError:
                continue
            for pattern in PATTERNS:
                if re.search(pattern, text):
                    return True
    return False

def main():
    sys.stdout.write('1' if needs_visa() else '0')

if __name__ == '__main__':
    main()
