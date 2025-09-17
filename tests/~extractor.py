import re
import sys
import os
import traceback

def main_logic():
    if len(sys.argv) < 2:
        print("Usage: python ~extractor.py <path_to_run_setup.bat>", file=sys.stderr)
        sys.exit(1)

    batch_file_path = sys.argv[1]
    script_dir = os.path.dirname(os.path.realpath(__file__))
    extract_dir = os.path.join(script_dir, "extracted")

    if not os.path.exists(batch_file_path):
        raise FileNotFoundError(f"run_setup.bat not found at expected path: {batch_file_path}")

    if not os.path.exists(extract_dir):
        os.makedirs(extract_dir)

    with open(batch_file_path, "r", encoding="ascii", errors="ignore") as f:
        content = f.read()

    pattern = re.compile(r"""call\s+:write_ps_file\s+"([^"]*emit_[^"]*\.ps1)"\s+"@'(.*?)'@" """, re.DOTALL)

    emitted_files = []
    matches_found = 0
    for match in pattern.finditer(content):
        matches_found += 1
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

    if matches_found == 0:
        # This is a critical debug step. If the main regex fails, we need to know.
        raise ValueError("Main regex did not find any `call :write_ps_file` blocks.")

    for fname in emitted_files:
        print(fname)

if __name__ == "__main__":
    log_file = os.path.join(os.path.dirname(os.path.realpath(__file__)), "~extractor.error.log")
    try:
        main_logic()
    except Exception as e:
        # If anything goes wrong, write detailed info to the log file.
        with open(log_file, "w", encoding="utf-8") as f:
            f.write(f"Extractor script failed!\n")
            f.write(f"Python version: {sys.version}\n")
            f.write(f"Arguments: {sys.argv}\n")
            f.write(f"CWD: {os.getcwd()}\n\n")
            f.write(f"Exception Type: {type(e).__name__}\n")
            f.write(f"Exception Message: {e}\n\n")
            f.write("Traceback:\n")
            f.write("="*20 + "\n")
            traceback.print_exc(file=f)

        # Also print a summary to stderr, which might be captured in other logs.
        print(f"FATAL: Extractor script failed. See {log_file} for details.", file=sys.stderr)
        sys.exit(1)
