"""File locations, relative to tools/dictgen/."""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
RAW_DIR = os.path.join(DATA_DIR, "raw")  # downloads; git-ignored
GLOSS_FILTER = os.path.join(DATA_DIR, "gloss_filter.txt")
REPORT = os.path.join(ROOT, "reports", "lexicon.gen.json")

REPO_ROOT = os.path.dirname(os.path.dirname(ROOT))
ACCEPTED = os.path.join(REPO_ROOT, "tools", "puzzlegen", "data", "accepted.txt")
SCOWL_LEVELS = os.path.join(REPO_ROOT, "tools", "puzzlegen", "data", "scowl_levels.tsv")  # report only
DICT_DIR = os.path.join(REPO_ROOT, "app", "assets", "dict")
LICENCE_TXT = os.path.join(REPO_ROOT, "app", "assets", "licenses", "OEWN-CC-BY-4.0.txt")
