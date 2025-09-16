import re
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("Usage: python ~extractor.py <path_to_run_setup.bat>", file=sys.stderr)
        sys.exit(1)

    batch_file_path = sys.argv[1]
    script_dir = os.path.dirname(os.path.realpath(__file__))
    extract_dir = os.path.join(script_dir, "extracted")

    if not os.path.exists(batch_file_path):
        print(f"Error: File not found at {batch_file_path}", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(extract_dir):
        os.makedirs(extract_dir)

    with open(batch_file_path, "r", encoding="ascii", errors="ignore") as f:
        content = f.read()

    pattern = re.compile(r"""call\s+:write_ps_file\s+"([^"]*emit_[^"]*\.ps1)"\s+"@'(.*?)'@" """, re.DOTALL)

    emitted_files = []

    for match in pattern.finditer(content):
        payload = match.group(2)

        outfile_match = re.search(r"\$OutFile\s*=\s*'([^']+\.py)'", payload)
        content_match = re.search(r"\$Content\s*=\s*@'(.*?)'@", payload, re.DOTALL)

        if outfile_match and content_match:
            out_file_name = outfile_match.group(1)
            script_content = content_match.group(1)

            dest_path = os.path.join(extract_dir, out_file_name)

            with open(dest_path, "w", encoding="ascii", newline="\r\n") as f_out:
                f_out.write(script_content)

            emitted_files.append(out_file_name)

    for fname in emitted_files:
        print(fname)

if __name__ == "__main__":
    main()
