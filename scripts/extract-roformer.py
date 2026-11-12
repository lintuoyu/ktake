import sys
from pathlib import Path

from separation_progress import ExtractionProgress


def load_model(cache, progress):
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    files = ("config.json", "model.safetensors")
    options = dict(
        repo_id="mlx-community/mel-roformer-kim-vocal-2-mlx",
        revision="64cbfcb004e39430e5f584552c05949440ec39ce",
        cache_dir=cache,
        allow_patterns=files,
    )
    try:
        model_dir = Path(snapshot_download(**options, local_files_only=True))
    except LocalEntryNotFoundError:
        model_dir = None
    if model_dir is None or not all((model_dir / name).is_file() for name in files):
        model_dir = Path(snapshot_download(**options))

    progress.update("loadingModel")
    from mlx_audio.sts.models.mel_roformer import MelRoFormer

    return MelRoFormer.from_pretrained(model_dir).eval()


def extract(source, destination, cache, progress_path=None):
    progress = ExtractionProgress(progress_path)
    progress.update("preparingModel")
    import mlx.core as mx
    import numpy as np
    import soundfile as sf

    audio, rate = sf.read(source, dtype="float32", always_2d=True)
    if rate != 44100 or audio.shape[1] != 2 or len(audio) == 0:
        raise ValueError("Expected nonempty 44.1 kHz stereo audio")

    model = load_model(cache, progress)
    chunk = 352800
    hop = chunk // 2
    ramp = np.linspace(0, 1, hop, dtype=np.float32)[:, None]
    accompaniment = np.zeros_like(audio)
    for start in progress.track(range(0, max(1, len(audio) - hop), hop)):
        segment = audio[start:start + chunk]
        block = np.zeros((2, chunk), dtype=np.float32)
        block[:, :len(segment)] = segment.T
        voice = np.asarray(model(mx.array(block[None]))[0], dtype=np.float32).T
        instrumental = segment - voice[:len(segment)]
        if start:
            instrumental[:hop] *= ramp
        if start + chunk < len(audio):
            instrumental[-hop:] *= 1 - ramp
        accompaniment[start:start + len(segment)] += instrumental

    peak = float(np.max(np.abs(accompaniment)))
    if not np.isfinite(peak):
        raise ValueError("Separation produced invalid audio samples")
    if peak > 1:
        accompaniment /= peak
    sf.write(destination, accompaniment, rate, subtype="PCM_24")


if __name__ == "__main__":
    extract(*sys.argv[1:])
