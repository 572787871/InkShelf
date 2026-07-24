# Bundled ZipVoice reference catalog

The five `studio_*.wav` files are clean, full-utterance reference prompts
selected from the Chinese speaker vectors published with
`hexgrad/Kokoro-82M-v1.1-zh`. The catalog was reduced from 103 entries after
checking duration, RMS level, clipping and silence ratio, keeping three female
and two male references with distinct delivery styles.

Source model and speaker vectors:
<https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh>

The source repository declares the Apache License 2.0 and describes the Chinese
speakers as coming from a professionally produced dataset. The clips were
generated locally with the repository's official `KModel`/`KPipeline` path at
24 kHz, trimmed only at near-digital-silence edges, DC-corrected, peak-limited,
and stored as mono 16-bit PCM WAV files. They were not made by duplicating or
renaming the two demonstration WAV files in the upstream repository.

All five files speak this exact transcript:

`夜色沉静，微风吹过长街。愿每一个故事，都有属于自己的声音。`

`catalog.json` provides stable product-facing Chinese names and gender metadata.
The upstream model name is intentionally not used as a voice name in the app;
this README retains the required engineering provenance and license context.
