"""Read an Open English WordNet (or any WN-LMF) XML file, plain or gzipped.

Only what the dictionary needs is kept: each lexical entry's lemma, part of
speech, senses (synset ids, in the file's sense order) and irregular forms
(OEWN's version of WordNet's exception lists), plus each synset's definition
and whether it names an individual (an instance: a person, place, deity).
The file is parsed as data with the standard library's expat parser, which
does not fetch the external DTD.
"""

from __future__ import annotations

import gzip
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

# WN-LMF part of speech -> dictionary pos. Satellite adjectives ("s") are adjectives.
POS = {"n": "n", "v": "v", "a": "a", "s": "a", "r": "r"}


@dataclass
class Entry:
    written: str  # lemma as written ("forge", "March", "ice cream")
    pos: str  # n, v, a or r
    synsets: list[str] = field(default_factory=list)
    forms: list[str] = field(default_factory=list)  # irregular inflections ("went" for go)


@dataclass
class WordNet:
    info: dict  # Lexicon attributes: id, label, version, license, url
    entries: list[Entry]  # file order
    definitions: dict[str, str]  # synset id -> definition (first one)
    instances: set[str] = field(default_factory=set)  # named entities (instance_hypernym): Paris, Mars


def load(path: str) -> WordNet:
    opener = gzip.open if path.endswith(".gz") else open
    info: dict = {}
    entries: list[Entry] = []
    definitions: dict[str, str] = {}
    instances: set[str] = set()
    with opener(path, "rb") as fh:
        parent = None  # the element holding entries and synsets; emptied as we go
        for event, elem in ET.iterparse(fh, events=("start", "end")):
            tag = elem.tag
            if event == "start":
                if parent is None:
                    parent = elem
                if tag == "Lexicon":
                    if not info:
                        info = dict(elem.attrib)
                    parent = elem
                continue
            if tag == "LexicalEntry":
                lemma = elem.find("Lemma")
                if lemma is not None and lemma.get("partOfSpeech") in POS:
                    entries.append(Entry(
                        written=lemma.get("writtenForm", ""),
                        pos=POS[lemma.get("partOfSpeech")],
                        synsets=[s.get("synset") for s in elem.findall("Sense") if s.get("synset")],
                        forms=[f.get("writtenForm") for f in elem.findall("Form") if f.get("writtenForm")],
                    ))
                parent.clear()
            elif tag == "Synset":
                d = elem.find("Definition")
                if d is not None and d.text:
                    definitions[elem.get("id")] = d.text
                if any(r.get("relType") == "instance_hypernym" for r in elem.findall("SynsetRelation")):
                    instances.add(elem.get("id"))
                parent.clear()
    return WordNet(info=info, entries=entries, definitions=definitions, instances=instances)
