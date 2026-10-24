"""File locations, relative to tools/puzzlegen/."""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
RAW_DIR = os.path.join(DATA_DIR, "raw")
REPORTS_DIR = os.path.join(ROOT, "reports")

ACCEPTED = os.path.join(DATA_DIR, "accepted.txt")
SCOWL_LEVELS = os.path.join(DATA_DIR, "scowl_levels.tsv")
SCOWL_ONLY = os.path.join(DATA_DIR, "scowl_only.txt")
BLOCKLIST = os.path.join(DATA_DIR, "blocklist.txt")
BLOCKLIST_EXTRA = os.path.join(DATA_DIR, "blocklist_extra.txt")
ANSWER_EXCLUDE = os.path.join(DATA_DIR, "answer_exclude.txt")
NAMES_EXCLUDE = os.path.join(DATA_DIR, "names_exclude.txt")
NAMES_KEEP = os.path.join(DATA_DIR, "names_keep.txt")
NAMES_EXTRA = os.path.join(DATA_DIR, "names_extra.txt")
LICENSES = os.path.join(DATA_DIR, "LICENSES.md")
FREQ = os.path.join(DATA_DIR, "freq.tsv")
NAME_SENSES = os.path.join(DATA_DIR, "name_senses.txt")
NOT_INFLECTIONS = os.path.join(DATA_DIR, "not_inflections.txt")

REPO_ROOT = os.path.dirname(os.path.dirname(ROOT))
CAMPAIGN_JSON = os.path.join(REPO_ROOT, "app", "assets", "campaign", "campaign.json")
MP_BANK_JSON = os.path.join(REPO_ROOT, "server", "data", "mp_bank.json")
# The app's word meanings (tools/dictgen): which words have one.
DICT_DIR = os.path.join(REPO_ROOT, "app", "assets", "dict")
