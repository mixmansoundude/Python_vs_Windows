"""Two-file example: main.py is the entry and imports helper.py from the same folder."""
import helper


def main():
    print(helper.greeting("multi-file example"))


if __name__ == "__main__":
    main()
