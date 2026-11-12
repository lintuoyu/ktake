import hashlib
import shutil
import tempfile
from pathlib import Path
from urllib.request import urlopen


def checksum(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def cached_model_file(cache, name, url, sha256):
    destination = cache / name
    if destination.is_file() and checksum(destination) == sha256:
        return destination
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache) as staging:
        candidate = Path(staging) / name
        with urlopen(url, timeout=60) as response, candidate.open("wb") as file:
            shutil.copyfileobj(response, file)
        if checksum(candidate) != sha256:
            raise ValueError(f"Model checksum mismatch: {name}")
        candidate.replace(destination)
    return destination
