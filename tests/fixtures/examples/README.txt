Example programs for run_setup.bat
==================================

Each folder here is a small, complete Python program. To try one:

  1. Copy run_setup.bat and the files from ONE folder into a new empty folder.
  2. Double-click run_setup.bat.

Nothing else needs to be installed first. The first run takes a few minutes
(it downloads a Python and builds a program in the "dist" folder); later runs
reuse it. Only copy one folder at a time: run_setup.bat treats every .py file
in its folder as part of one program.

  stdlib_single      solo.py. Uses only what comes with Python. Prints
                     "from-single".

  multifile_sibling  main.py and helper.py. main.py imports helper.py from the
                     same folder; the bootstrapper must pick main.py as the
                     entry and must not try to install "helper" as a package.
                     Prints "hello from helper: multi-file example".

  gui_exits          app.py. Opens a small tkinter window and closes it by
                     itself after half a second, then prints "window closed".

  pandas_excel       app.py and requirements.txt. Needs pandas and openpyxl
                     (installed for you). Writes out.xlsx next to the program.

The automatic tests in this repository (tests/selfapps_example_apps.ps1 and
tests/selfapps_pandas_excel.ps1) use these exact files, so they stay working.
