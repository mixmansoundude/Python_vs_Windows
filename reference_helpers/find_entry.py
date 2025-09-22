import os

def find_entry():
    files = [name for name in os.listdir('.') if name.endswith('.py') and not name.startswith('~')]
    for name in files:
        try:
            with open(name, 'r', encoding='utf-8', errors='ignore') as handle:
                text = handle.read()
            if "if __name__ == '__main__'" in text:
                return name
        except Exception:
            continue
    return files[0] if files else ''

print(find_entry())
