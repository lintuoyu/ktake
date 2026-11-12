import json
import time
from collections import deque
from contextlib import contextmanager
from pathlib import Path


class ExtractionProgress:
    def __init__(self, path=None):
        self.path = Path(path) if path is not None else None

    def update(self, phase, completed=None, total=None, remaining_seconds=None):
        if self.path is None:
            return
        snapshot = {
            "phase": phase,
            "completed": completed,
            "total": total,
            "remainingSeconds": remaining_seconds,
        }
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(snapshot), encoding="utf-8")
        temporary.replace(self.path)

    def track(self, batches, *, total=None, **_):
        if self.path is None:
            yield from batches
            return
        total = len(batches) if total is None else total
        self.update("separating", 0, total)
        durations = deque(maxlen=8)
        for completed, batch in enumerate(batches, start=1):
            started = time.monotonic()
            yield batch
            # The first batch can include model warm-up.
            if completed > 1:
                durations.append(time.monotonic() - started)
            if completed == total:
                self.update("saving")
            else:
                remaining = None
                if len(durations) >= 2:
                    remaining = (total - completed) * sum(durations) / len(durations)
                self.update("separating", completed, total, remaining)

    @contextmanager
    def report_batches(self, module, name):
        if self.path is None:
            yield
            return
        original = getattr(module, name)
        setattr(module, name, self.track)
        try:
            yield
        finally:
            setattr(module, name, original)
