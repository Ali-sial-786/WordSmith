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
LICENSES = os.path.join(DATA_DIR, "LICENSES.md")

REPO_ROOT = os.path.dirname(os.path.dirname(ROOT))
CAMPAIGN_JSON = os.path.join(REPO_ROOT, "app", "assets", "campaign", "campaign.json")
MP_BANK_JSON = os.path.join(REPO_ROOT, "server", "data", "mp_bank.json")
